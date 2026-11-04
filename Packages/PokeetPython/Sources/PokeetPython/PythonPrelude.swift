import Foundation

/// Runs once in the interpreter, before any script.
///
/// `builtins.open` and `io.open` are redirected so a script reads and writes the
/// project, not the container. Everything else is left alone on purpose: patching
/// `os` would break the import machinery, which needs to see the real stdlib on disk.
enum PythonPrelude {
    static let source = #"""
import builtins as _builtins
import io as _io
import json as _json

import _pokeet as _host


def _call(operation, **kwargs):
    return _json.loads(_host.call(operation, _json.dumps(kwargs)))


class SandboxFile:
    """A text file backed by the sandbox filesystem.

    Writes are buffered for the lifetime of the handle and handed over on close, so
    one file produces one diff proposal. Nothing reaches the project until the user
    approves the proposal.
    """

    def __init__(self, path, mode="r"):
        if "b" in mode:
            raise NotImplementedError(
                "binary mode is not available in the sandbox; use text mode"
            )
        mode = mode.replace("t", "").replace("+", "") or "r"
        if mode not in ("r", "w", "a"):
            raise ValueError("unsupported mode %r" % mode)

        self.name = str(path)
        self.mode = mode
        self._append = mode == "a"
        self._writable = mode in ("w", "a")
        self._closed = False
        self._buffer = ""
        self._position = 0
        if self._writable:
            # Fail at open, not at close: a path outside the project must never wait
            # for a flush that may never come.
            _call("fs.check", path=self.name)
            self._content = ""
        else:
            self._content = _call("fs.read", path=self.name)["content"]

    # -- reading ---------------------------------------------------------
    def readable(self):
        return not self._writable

    def read(self, size=-1):
        self._assert_open()
        text = self._content[self._position:]
        if size is not None and size >= 0:
            text = text[:size]
        self._position += len(text)
        return text

    def readline(self, size=-1):
        self._assert_open()
        rest = self._content[self._position:]
        index = rest.find("\n")
        text = rest if index < 0 else rest[:index + 1]
        if size is not None and size >= 0:
            text = text[:size]
        self._position += len(text)
        return text

    def readlines(self, hint=-1):
        lines, total = [], 0
        for line in self:
            lines.append(line)
            total += len(line)
            if hint is not None and 0 <= hint <= total:
                break
        return lines

    def __iter__(self):
        return self

    def __next__(self):
        line = self.readline()
        if not line:
            raise StopIteration
        return line

    # -- writing ---------------------------------------------------------
    def writable(self):
        return self._writable

    def write(self, text):
        self._assert_open()
        if not self._writable:
            raise _io.UnsupportedOperation("not writable")
        text = str(text)
        self._buffer += text
        return len(text)

    def writelines(self, lines):
        for line in lines:
            self.write(line)

    def flush(self):
        if self._writable and self._buffer:
            _call("fs.write", path=self.name, content=self._buffer, append=self._append)
            self._append = True  # a second flush appends instead of replacing
            self._buffer = ""

    def close(self):
        if self._closed:
            return
        self.flush()
        self._closed = True

    def __del__(self):
        try:
            self.close()
        except Exception:
            pass

    # -- misc ------------------------------------------------------------
    def seek(self, offset, whence=0):
        if whence == 0:
            self._position = offset
        elif whence == 1:
            self._position += offset
        else:
            self._position = len(self._content) + offset
        return self._position

    def tell(self):
        return self._position

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        return False

    def _assert_open(self):
        if self._closed:
            raise ValueError("I/O operation on closed file")


# -- filesystem helpers ---------------------------------------------------
def read(path):
    """Return the full text of a project file."""
    return _call("fs.read", path=str(path))["content"]


def write(path, content):
    """Stage a full-file write. Returns the number of characters written."""
    _call("fs.write", path=str(path), content=str(content), append=False)
    return len(str(content))


def append(path, content):
    _call("fs.write", path=str(path), content=str(content), append=True)
    return len(str(content))


def listdir(path="."):
    """Names directly under `path`, sorted. Paths are relative to the project root."""
    entries = _call("fs.list", path=str(path), recursive=False)["entries"]
    return sorted(entry["path"].split("/")[-1] for entry in entries)


def walk(path="."):
    """Every path under `path`, relative to the project root."""
    entries = _call("fs.list", path=str(path), recursive=True)["entries"]
    return sorted(entry["path"] for entry in entries)


def exists(path):
    return _call("fs.exists", path=str(path))["exists"]


def info(path):
    return _call("fs.info", path=str(path))


# -- urllib.request, backed by the host -------------------------------
#
# The real urllib needs sockets, and sockets would walk around every policy the app
# enforces. This is the same API over the host bridge: urlopen(url) -> response with
# .read(), .status, .headers.
import sys as _sys
import types as _types


class HTTPMessage:
    """Case-insensitive header bag, the way http.client's looks to callers."""

    def __init__(self, pairs):
        self._map = {}
        for name, value in pairs:
            self._map[str(name).lower()] = str(value)

    def get(self, name, default=None):
        return self._map.get(str(name).lower(), default)

    def get_all(self, name):
        value = self.get(name)
        return [] if value is None else [value]

    def items(self):
        return list(self._map.items())

    def __getitem__(self, name):
        value = self.get(name)
        if value is None:
            raise KeyError(name)
        return value

    def __contains__(self, name):
        return str(name).lower() in self._map

    def __iter__(self):
        return iter(self._map)


class HTTPResponse:
    def __init__(self, raw):
        self.status = raw["status"]
        self.code = raw["status"]
        self.url = raw["url"]
        self.headers = HTTPMessage(raw.get("headers") or [])
        self.truncated = bool(raw.get("truncated"))
        self.redirect_note = raw.get("redirectNote") or ""
        self._body = (raw.get("body") or "").encode("utf-8")
        self._offset = 0

    def read(self, amount=-1):
        if amount is None or amount < 0:
            chunk = self._body[self._offset:]
            self._offset = len(self._body)
        else:
            chunk = self._body[self._offset:self._offset + amount]
            self._offset += len(chunk)
        return chunk

    def readline(self):
        rest = self._body[self._offset:]
        index = rest.find(b"\n")
        chunk = rest if index < 0 else rest[:index + 1]
        self._offset += len(chunk)
        return chunk

    def geturl(self):
        return self.url

    def getcode(self):
        return self.status

    def info(self):
        return self.headers

    def close(self):
        pass

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        return False


def urlopen(url, data=None, timeout=None, *, headers=None, method=None):
    """Open `url` through the app's network policy."""
    if isinstance(url, bytes):
        url = url.decode("utf-8")
    target = str(url)
    verb = (method or ("POST" if data is not None else "GET")).upper()
    body = ""
    if data is not None:
        body = data.decode("utf-8") if isinstance(data, bytes) else str(data)
    raw = _call("net.request", url=target, method=verb, headers=headers or {}, body=body)
    return HTTPResponse(raw)


def _install_urllib():
    try:
        import urllib as package          # the real package: urllib.parse still lives there
    except ImportError:
        package = _types.ModuleType("urllib")
        package.__path__ = []
        _sys.modules["urllib"] = package

    request_module = _types.ModuleType("urllib.request")
    request_module.urlopen = urlopen
    request_module.Request = object  # accepted, not modelled
    request_module.HTTPError = OSError
    request_module.URLError = OSError
    _sys.modules["urllib.request"] = request_module
    package.request = request_module


def _guarded_json_load(stream, *args, **kwargs):
    """json.load on a truncated response would fail as a syntax error."""
    if getattr(stream, "truncated", False):
        raise ValueError(
            "the response was truncated before the end of the body; "
            "it is too large to parse in one piece"
        )
    return _original_json_load(stream, *args, **kwargs)


import json as _json_module
_original_json_load = _json_module.load
_json_module.load = _guarded_json_load

_install_urllib()


# -- the filesystem, as much as the sandbox can honour -------------------
#
# The interpreter's working directory is "/" — the app's own sandbox — so anything
# unredirected answers a question about the wrong disk. These shims cover the read
# side: stat, scandir, walk and glob, which is what pathlib and the stdlib build on.
# Import machinery does not use them, so patching after startup is safe.
#
# Delete, rename and mkdir are deliberately absent: the sandbox has no such
# operation, and a script that could remove files would be a different feature.
import os as _os
import stat as _statmod
import time as _time

_os.getcwd = lambda: "/"


def _abspath(path):
    text = str(path)
    return "/" + text.lstrip("/")


_os.path.abspath = _abspath
_os.path.realpath = _abspath


def _entry(path):
    """`info` for a path that must exist, raising FileNotFoundError like the real os."""
    if not exists(path):
        raise FileNotFoundError(2, "No such file or directory", str(path))
    return info(path)


def _stat_result(raw, path):
    is_dir = raw["isDirectory"]
    mode = (_statmod.S_IFDIR | 0o755) if is_dir else (_statmod.S_IFREG | 0o644)
    stamp = raw.get("modified") or 0
    return _os.stat_result(
        (mode, 0, 0, 1, 0, 0, raw["size"], stamp, stamp, stamp)
    )


def _stat_path(path=".", *, dir_fd=None, follow_symlinks=True):
    return _stat_result(_entry(path), path)


_os.stat = _stat_path
_os.lstat = _stat_path


def _getmtime(path):
    return _entry(path).get("modified") or 0


_os.path.getmtime = _getmtime
_os.path.getctime = _getmtime
_os.path.getatime = _getmtime


class _DirEntry:
    """Shaped like os.DirEntry: what glob and pathlib actually touch.

    Only `name` and `is_dir()` are free — `fs.list` already answered those. A
    stat costs one host call, so it waits until somebody asks.
    """

    def __init__(self, name, path, is_directory):
        self.name = name
        self.path = path
        self._is_dir = is_directory

    def is_dir(self, *, follow_symlinks=True):
        return self._is_dir

    def is_file(self, *, follow_symlinks=True):
        return not self._is_dir

    def is_symlink(self):
        return False

    def stat(self, *, follow_symlinks=True):
        return _stat_result(_entry(self.path), self.path)

    def __fspath__(self):
        return self.path

    def __repr__(self):
        return "<DirEntry %r>" % (self.path,)


class _ScandirIterator:
    def __init__(self, path):
        self._entries = list(_scandir_entries(path))
        self._index = 0

    def __iter__(self):
        return self

    def __next__(self):
        if self._index >= len(self._entries):
            raise StopIteration
        entry = self._entries[self._index]
        self._index += 1
        return entry

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        return False

    def close(self):
        self._index = len(self._entries)


def _scandir_entries(path):
    text = str(path) if path is not None else "."
    base = "" if text in ("", ".", "/") else text.strip("/")
    for item in _call("fs.list", path=base, recursive=False)["entries"]:
        full = item["path"]
        yield _DirEntry(full.split("/")[-1], full, item["isDirectory"])


def _scandir(path="."):
    return _ScandirIterator(path)


_os.scandir = _scandir
_os.listdir = lambda path=".": [entry.name for entry in _scandir(path)]


def _walk(top=".", topdown=True, onerror=None, followlinks=False):
    """Same contract as os.walk: yields (dirpath, dirnames, filenames)."""
    top = str(top).strip("/") or "."
    try:
        entries = list(_scandir(top))
    except OSError as error:
        if onerror is not None:
            onerror(error)
        return
    dirnames = [entry.name for entry in entries if entry.is_dir()]
    filenames = [entry.name for entry in entries if entry.is_file()]
    yield (top, dirnames, filenames)
    for name in dirnames:
        child = name if top in (".", "") else top + "/" + name
        yield from _walk(child, topdown, onerror, followlinks)


_os.walk = _walk


def _is_file(path):
    return exists(path) and not info(path)["isDirectory"]


def _is_dir(path):
    return exists(path) and info(path)["isDirectory"]


def _size(path):
    return _entry(path)["size"]


_os.path.exists = exists
_os.path.isfile = _is_file
_os.path.isdir = _is_dir
_os.path.getsize = _size


# -- redirect open() ------------------------------------------------------
def _sandboxed_open(file, mode="r", *args, **kwargs):
    if isinstance(file, int):
        raise TypeError("sandbox files are opened by path, not by file descriptor")
    return SandboxFile(file, mode or "r")


_builtins.open = _sandboxed_open
_io.open = _sandboxed_open
"""#
}
