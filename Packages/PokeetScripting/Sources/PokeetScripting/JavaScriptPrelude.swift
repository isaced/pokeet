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

      var Response = function (raw) {
        this.status = raw.status;
        this.ok = raw.status >= 200 && raw.status < 300;
        this.statusText = '';
        this.url = raw.url;
        this.redirected = false;
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
        return new Response(raw);
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
        cwd: function () { return ''; },
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

      global.__pokeet = { runtime: 'quickjs', args: process.argv.slice(1) };
    })(globalThis);
    """#
}
