import Foundation

extension QuickJSRuntime {
    /// Sandbox API injected into every run. Everything here funnels through the single
    /// `__hostCall` bridge, so the C surface stays tiny and the policy stays in Swift.
    static let prelude: String = #"""
    (function (global) {
      'use strict';

      var call = function (operation, args) {
        var payload = global.__hostCall(operation, JSON.stringify(args || {}));
        return payload ? JSON.parse(payload) : null;
      };

      var inspect = function (value) {
        if (typeof value === 'string') return value;
        if (value === null) return 'null';
        if (value === undefined) return 'undefined';
        if (typeof value === 'number' || typeof value === 'boolean') return String(value);
        if (typeof value === 'bigint') return String(value) + 'n';
        if (typeof value === 'function') return '[Function ' + (value.name || 'anonymous') + ']';
        if (value instanceof Error) return value.stack || (value.name + ': ' + value.message);
        try { return JSON.stringify(value); } catch (error) { return String(value); }
      };

      var format = function (args) {
        var parts = [];
        for (var index = 0; index < args.length; index += 1) parts.push(inspect(args[index]));
        return parts.join(' ');
      };

      var write = function (level, args) {
        call('log', { level: level, text: format(args) });
      };

      global.console = {
        log: function () { write('log', arguments); },
        info: function () { write('info', arguments); },
        debug: function () { write('log', arguments); },
        warn: function () { write('warn', arguments); },
        error: function () { write('error', arguments); }
      };

      global.print = function () { write('log', arguments); };

      var assert = function (condition, message) {
        if (!condition) throw new Error(message || 'Assertion failed');
      };
      assert.equal = function (actual, expected, message) {
        if (!Object.is(actual, expected)) {
          throw new Error((message ? message + ': ' : '') + 'expected ' + inspect(expected) + ', got ' + inspect(actual));
        }
      };
      assert.notEqual = function (actual, unexpected, message) {
        if (Object.is(actual, unexpected)) {
          throw new Error((message ? message + ': ' : '') + 'did not expect ' + inspect(unexpected));
        }
      };
      assert.deepEqual = function (actual, expected, message) {
        var left = JSON.stringify(actual);
        var right = JSON.stringify(expected);
        if (left !== right) {
          throw new Error((message ? message + ': ' : '') + 'expected ' + right + ', got ' + left);
        }
      };
      assert.throws = function (fn, message) {
        var threw = false;
        try { fn(); } catch (error) { threw = true; }
        if (!threw) throw new Error(message || 'Expected the function to throw');
      };
      global.assert = assert;

      var fs = {
        read: function (path) { return call('fs.read', { path: String(path) }).content; },
        write: function (path, content) {
          var text = typeof content === 'string' ? content : JSON.stringify(content, null, 2);
          call('fs.write', { path: String(path), content: text });
        },
        append: function (path, content) {
          var previous = fs.exists(path) ? fs.read(path) : '';
          fs.write(path, previous + content);
        },
        exists: function (path) { return call('fs.exists', { path: String(path) }).exists; },
        info: function (path) { return call('fs.info', { path: String(path) }); },
        list: function (path) { return call('fs.list', { path: path ? String(path) : '', recursive: false }).entries; },
        listRecursive: function (path) { return call('fs.list', { path: path ? String(path) : '', recursive: true }).entries; }
      };
      fs.readText = fs.read;
      fs.readdir = fs.list;
      fs.readJSON = function (path) { return JSON.parse(fs.read(path)); };

      // Node-shaped names, so a snippet written for `fs` in Node runs unchanged.
      var encodingOf = function (options) {
        if (!options) return null;
        if (typeof options === 'string') return options;
        return options.encoding || null;
      };
      var textOf = function (data, options) {
        if (typeof data === 'string') return data;
        if (data && typeof data.byteLength === 'number') return String.fromCharCode.apply(null, data);
        var encoding = encodingOf(options);
        if (encoding) throw new TypeError('the sandbox only stores text');
        return JSON.stringify(data, null, 2);
      };

      fs.readFileSync = function (path, options) {
        var text = fs.read(path);
        var encoding = encodingOf(options);
        if (encoding === 'buffer' || encoding === null) {
          // Node returns a Buffer by default; text is all we have, so hand back bytes.
          return text;
        }
        return text;
      };
      fs.writeFileSync = function (path, data, options) { fs.write(path, textOf(data, options)); };
      fs.appendFileSync = function (path, data, options) { fs.append(path, textOf(data, options)); };
      fs.readdirSync = function (path) {
        return fs.list(path).map(function (entry) { return entry.path.split('/').pop(); });
      };
      fs.existsSync = function (path) { return fs.exists(path); };
      fs.statSync = function (path) {
        if (!fs.exists(path)) {
          var missing = new Error("ENOENT: no such file or directory, stat '" + path + "'");
          missing.code = 'ENOENT';
          throw missing;
        }
        var raw = fs.info(path);
        return {
          size: raw.size,
          mtimeMs: (raw.modified || 0) * 1000,
          isFile: function () { return !raw.isDirectory; },
          isDirectory: function () { return !!raw.isDirectory; },
          isSymbolicLink: function () { return false; }
        };
      };
      var notSupported = function (name) {
        return function () {
          var error = new Error('fs.' + name + ' is not available in the sandbox');
          error.code = 'ENOSYS';
          throw error;
        };
      };
      fs.mkdirSync = notSupported('mkdirSync');
      fs.rmdirSync = notSupported('rmdirSync');
      fs.unlinkSync = notSupported('unlinkSync');
      fs.renameSync = notSupported('renameSync');
      fs.rmSync = notSupported('rmSync');

      global.fs = fs;

      var Headers = function (init) {
        this._map = {};
        if (init) {
          for (var key in init) this.set(key, init[key]);
        }
      };
      Headers.prototype.set = function (name, value) {
        this._map[String(name).toLowerCase()] = String(value);
      };
      Headers.prototype.get = function (name) {
        var value = this._map[String(name).toLowerCase()];
        return value === undefined ? null : value;
      };
      Headers.prototype.has = function (name) {
        return this._map[String(name).toLowerCase()] !== undefined;
      };
      Headers.prototype.forEach = function (fn) {
        for (var key in this._map) fn(this._map[key], key);
      };

      var STATUS_TEXT = {
        200: 'OK', 201: 'Created', 202: 'Accepted', 204: 'No Content',
        206: 'Partial Content', 301: 'Moved Permanently', 302: 'Found',
        303: 'See Other', 304: 'Not Modified', 307: 'Temporary Redirect',
        308: 'Permanent Redirect', 400: 'Bad Request', 401: 'Unauthorized',
        403: 'Forbidden', 404: 'Not Found', 405: 'Method Not Allowed',
        409: 'Conflict', 410: 'Gone', 422: 'Unprocessable Content',
        429: 'Too Many Requests', 500: 'Internal Server Error',
        502: 'Bad Gateway', 503: 'Service Unavailable', 504: 'Gateway Timeout'
      };

      var Response = function (raw, requestedUrl) {
        this.status = raw.status;
        this.ok = raw.status >= 200 && raw.status < 300;
        this.statusText = STATUS_TEXT[raw.status] || '';
        this.url = raw.url;
        this.redirected = requestedUrl !== undefined && String(requestedUrl) !== raw.url;
        this.bodyUsed = false;
        this._body = raw.body;
        this.truncated = !!raw.truncated;
        this.headers = new Headers({});
        var pairs = raw.headers || [];
        for (var i = 0; i < pairs.length; i++) this.headers.set(pairs[i][0], pairs[i][1]);
      };
      // Values, not promises: `await` on a non-thenable yields the value, so the
      // fetch path still reads naturally while http.get stays synchronous.
      Response.prototype.text = function () {
        this.bodyUsed = true;
        return this._body;
      };
      Response.prototype.json = function () {
        this.bodyUsed = true;
        if (this.truncated) {
          throw new Error(
            'the response was truncated before the end of the body; it is too large to parse'
          );
        }
        return JSON.parse(this._body);
      };

      // Synchronous on purpose: the interpreter already has a deadline, and a request
      // that outlives it is cancelled with the run.
      var request = function (url, init) {
        var options = init || {};
        var method = String(options.method || 'GET').toUpperCase();
        var headers = {};
        if (options.headers) {
          for (var key in options.headers) headers[key] = String(options.headers[key]);
        }
        var body = options.body;
        var raw = call('net.request', {
          url: String(url),
          method: method,
          headers: headers,
          body: body === undefined || body === null ? '' : String(body)
        });
        return new Response(raw, String(url));
      };

      global.http = {
        request: request,
        get: function (url, init) {
          var options = init || {};
          options.method = 'GET';
          return request(url, options);
        },
        post: function (url, body, init) {
          var options = init || {};
          options.method = 'POST';
          options.body = body;
          return request(url, options);
        }
      };

      global.fetch = function (url, init) {
        return Promise.resolve().then(function () {
          return request(url, init);
        });
      };

      var path = {
        sep: '/',
        normalize: function (value) {
          var parts = String(value).split('/');
          var out = [];
          for (var index = 0; index < parts.length; index += 1) {
            var part = parts[index];
            if (part === '' || part === '.') continue;
            if (part === '..') { out.pop(); continue; }
            out.push(part);
          }
          return out.join('/');
        },
        join: function () {
          var parts = [];
          for (var index = 0; index < arguments.length; index += 1) parts.push(String(arguments[index]));
          return path.normalize(parts.join('/'));
        },
        dirname: function (value) {
          var parts = path.normalize(value).split('/');
          parts.pop();
          return parts.join('/');
        },
        basename: function (value) {
          var parts = path.normalize(value).split('/');
          return parts[parts.length - 1] || '';
        },
        extname: function (value) {
          var base = path.basename(value);
          var index = base.lastIndexOf('.');
          return index > 0 ? base.slice(index) : '';
        },
        isAbsolute: function (value) { return String(value).charAt(0) === '/'; },
        resolve: function () {
          var parts = [];
          for (var index = 0; index < arguments.length; index += 1) parts.push(String(arguments[index]));
          return path.normalize(parts.join('/'));
        }
      };
      global.path = path;

      var process = {
        argv: ['script'].concat(global.__pokeetArgs || []),
        env: {},
        cwd: function () { return '/'; },
        exit: function (code) {
          call('process.exit', { code: code === undefined ? 0 : Number(code) | 0 });
          throw new Error('__pokeet_exit__');
        }
      };
      global.process = process;

      var moduleCache = {};

      var resolveModule = function (request, fromDirectory) {
        var base = path.join(fromDirectory, request);
        var candidates = [base, base + '.js', base + '.json', base + '/index.js'];
        for (var index = 0; index < candidates.length; index += 1) {
          var candidate = candidates[index];
          if (!candidate) continue;
          if (fs.exists(candidate) && !fs.info(candidate).isDirectory) return candidate;
        }
        throw new Error(
          "Cannot find module '" + request + "' (looked for " + base + "). " +
          'Only relative files inside the repository are available: the sandbox has no node_modules and no network.'
        );
      };

      var loadModule = function (filename) {
        if (moduleCache[filename]) return moduleCache[filename].exports;
        var module = { id: filename, filename: filename, exports: {} };
        moduleCache[filename] = module;
        var source = fs.read(filename);
        if (/[.]json$/.test(filename)) {
          module.exports = JSON.parse(source);
          return module.exports;
        }
        var directory = path.dirname(filename);
        var localRequire = function (request) { return loadModule(resolveModule(request, directory)); };
        var factory = new Function(
          'module', 'exports', 'require', 'console', 'process', 'fs', 'path', '__filename', '__dirname',
          source + '\n'
        );
        factory(module, module.exports, localRequire, global.console, process, fs, path, filename, directory);
        return module.exports;
      };

      // Node core modules the sandbox can honestly answer. Anything else still goes
      // through the relative-file loader, which refuses unknown packages by name.
      var builtinModules = {
        fs: fs,
        path: path,
        os: { EOL: '\n', platform: function () { return 'ios'; }, homedir: function () { return '/'; } }
      };
      global.require = function (request) {
        var name = String(request).replace(/^node:/, '');
        if (Object.prototype.hasOwnProperty.call(builtinModules, name)) return builtinModules[name];
        return loadModule(resolveModule(request, ''));
      };

      // -- globals a script expects to exist ------------------------------
      //
      // QuickJS is bare ECMAScript: no URL, no timers, no base64, no text codecs.
      // Their absence surfaces as a ReferenceError, which reads like a broken
      // sandbox rather than a missing feature, so the common ones are provided.

      var URLSearchParams = function (init) {
        this._entries = [];
        if (typeof init === 'string') {
          var text = init.charAt(0) === '?' ? init.slice(1) : init;
          if (text) {
            var pairs = text.split('&');
            for (var index = 0; index < pairs.length; index += 1) {
              if (!pairs[index]) continue;
              var split = pairs[index].split('=');
              this.append(decodeURIComponent(split[0]), decodeURIComponent(split.slice(1).join('=') || ''));
            }
          }
        } else if (init && typeof init === 'object') {
          for (var key in init) this.append(key, init[key]);
        }
      };
      URLSearchParams.prototype.append = function (name, value) {
        this._entries.push([String(name), String(value)]);
      };
      URLSearchParams.prototype.get = function (name) {
        for (var index = 0; index < this._entries.length; index += 1) {
          if (this._entries[index][0] === String(name)) return this._entries[index][1];
        }
        return null;
      };
      URLSearchParams.prototype.getAll = function (name) {
        var out = [];
        for (var index = 0; index < this._entries.length; index += 1) {
          if (this._entries[index][0] === String(name)) out.push(this._entries[index][1]);
        }
        return out;
      };
      URLSearchParams.prototype.has = function (name) {
        return this.get(name) !== null;
      };
      URLSearchParams.prototype.set = function (name, value) {
        for (var index = 0; index < this._entries.length; index += 1) {
          if (this._entries[index][0] === String(name)) {
            this._entries[index][1] = String(value);
            return;
          }
        }
        this.append(name, value);
      };
      URLSearchParams.prototype['delete'] = function (name) {
        var kept = [];
        for (var index = 0; index < this._entries.length; index += 1) {
          if (this._entries[index][0] !== String(name)) kept.push(this._entries[index]);
        }
        this._entries = kept;
      };
      URLSearchParams.prototype.toString = function () {
        var parts = [];
        for (var index = 0; index < this._entries.length; index += 1) {
          parts.push(
            encodeURIComponent(this._entries[index][0]) + '=' + encodeURIComponent(this._entries[index][1])
          );
        }
        return parts.join('&');
      };
      URLSearchParams.prototype.forEach = function (fn) {
        for (var index = 0; index < this._entries.length; index += 1) {
          fn(this._entries[index][1], this._entries[index][0], this);
        }
      };
      URLSearchParams.prototype.entries = function () { return this._entries.slice(); };
      global.URLSearchParams = URLSearchParams;

      var URL = function (input, base) {
        var text = String(input);
        if (!/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(text) && base) {
          var baseText = String(base);
          var root = baseText.match(/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\/[^/]*/);
          text = root ? root[0] + (text.charAt(0) === '/' ? '' : '/') + text : text;
        }
        var match = text.match(/^([a-zA-Z][a-zA-Z0-9+.-]*):\/\/([^/?#]*)([^?#]*)(\?[^#]*)?(#.*)?$/);
        if (!match) throw new TypeError('Invalid URL: ' + text);
        this.protocol = match[1] + ':';
        this.host = match[2];
        this.hostname = match[2].split(':')[0];
        this.port = match[2].indexOf(':') >= 0 ? match[2].split(':')[1] : '';
        this.pathname = match[3] || '/';
        this.search = match[4] || '';
        this.hash = match[5] || '';
        this.origin = this.protocol + '//' + this.host;
        this.searchParams = new URLSearchParams(this.search);
      };
      URL.prototype.toString = function () {
        var query = this.searchParams.toString();
        return this.origin + this.pathname + (query ? '?' + query : '') + this.hash;
      };
      URL.prototype.toJSON = function () { return this.toString(); };
      Object.defineProperty(URL.prototype, 'href', {
        get: function () { return this.toString(); }
      });
      global.URL = URL;

      global.atob = function (input) {
        var alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
        var text = String(input).replace(/[^A-Za-z0-9+/]/g, '');
        var out = '';
        for (var index = 0; index < text.length; index += 4) {
          var chunk = text.slice(index, index + 4);
          var bits = 0;
          for (var offset = 0; offset < 4; offset += 1) {
            bits = (bits << 6) | (offset < chunk.length ? alphabet.indexOf(chunk.charAt(offset)) & 63 : 0);
          }
          out += String.fromCharCode((bits >> 16) & 255);
          if (chunk.length > 2) out += String.fromCharCode((bits >> 8) & 255);
          if (chunk.length > 3) out += String.fromCharCode(bits & 255);
        }
        return out;
      };
      global.btoa = function (input) {
        var alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
        var text = String(input);
        var out = '';
        for (var index = 0; index < text.length; index += 3) {
          var a = text.charCodeAt(index);
          var b = index + 1 < text.length ? text.charCodeAt(index + 1) : NaN;
          var c = index + 2 < text.length ? text.charCodeAt(index + 2) : NaN;
          out += alphabet.charAt(a >> 2);
          out += alphabet.charAt(((a & 3) << 4) | (isNaN(b) ? 0 : b >> 4));
          out += isNaN(b) ? '=' : alphabet.charAt(((b & 15) << 2) | (isNaN(c) ? 0 : c >> 6));
          out += isNaN(c) ? '=' : alphabet.charAt(c & 63);
        }
        return out;
      };

      global.TextEncoder = function () {};
      TextEncoder.prototype.encode = function (text) {
        var source = String(text);
        var bytes = [];
        for (var index = 0; index < source.length; index += 1) {
          var code = source.codePointAt(index);
          if (code > 0xffff) index += 1;
          if (code < 0x80) bytes.push(code);
          else if (code < 0x800) bytes.push(0xc0 | (code >> 6), 0x80 | (code & 63));
          else if (code < 0x10000) {
            bytes.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 63), 0x80 | (code & 63));
          } else {
            bytes.push(
              0xf0 | (code >> 18), 0x80 | ((code >> 12) & 63),
              0x80 | ((code >> 6) & 63), 0x80 | (code & 63)
            );
          }
        }
        return new Uint8Array(bytes);
      };

      global.TextDecoder = function () {};
      TextDecoder.prototype.decode = function (buffer) {
        if (!buffer) return '';
        var bytes = buffer instanceof Uint8Array ? buffer : new Uint8Array(buffer);
        var out = '';
        for (var index = 0; index < bytes.length;) {
          var byte = bytes[index];
          if (byte < 0x80) { out += String.fromCharCode(byte); index += 1; }
          else if (byte < 0xe0) {
            out += String.fromCharCode(((byte & 31) << 6) | (bytes[index + 1] & 63)); index += 2;
          } else if (byte < 0xf0) {
            out += String.fromCharCode(((byte & 15) << 12) | ((bytes[index + 1] & 63) << 6) | (bytes[index + 2] & 63));
            index += 3;
          } else {
            var code = ((byte & 7) << 18) | ((bytes[index + 1] & 63) << 12)
              | ((bytes[index + 2] & 63) << 6) | (bytes[index + 3] & 63);
            code -= 0x10000;
            out += String.fromCharCode(0xd800 + (code >> 10), 0xdc00 + (code & 1023));
            index += 4;
          }
        }
        return out;
      };

      // No event loop: a delay would be a lie, but a missing timer is a crash.
      // The callback runs on the microtask queue, so ordering holds and the delay
      // does not.
      global.setTimeout = function (fn) {
        Promise.resolve().then(function () {
          if (typeof fn === 'function') fn();
        });
        return 0;
      };
      global.clearTimeout = function () {};
      global.setInterval = function () {
        throw new Error('setInterval is not available: the sandbox has no event loop');
      };

      global.__pokeet = { runtime: 'quickjs', args: process.argv.slice(1) };
    })(globalThis);
    """#
}
