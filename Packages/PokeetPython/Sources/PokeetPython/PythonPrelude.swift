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


# -- redirect the parts of os that would otherwise read the real disk ------
#
# The interpreter's working directory is "/" — the app's own sandbox — so an
# unredirected os.listdir(".") lists system directories and quietly answers the
# wrong question. Import machinery does not go through these functions, so
# patching them after startup is safe; os.scandir is left raising rather than
# returning the wrong thing.
import os as _os

_os.getcwd = lambda: "/"
_os.listdir = listdir
_os.path.exists = exists


def _is_file(path):
    return exists(path) and not info(path)["isDirectory"]


def _is_dir(path):
    return exists(path) and info(path)["isDirectory"]


def _size(path):
    return info(path)["size"]


_os.path.isfile = _is_file
_os.path.isdir = _is_dir
_os.path.getsize = _size


def _scandir(path="."):
    raise NotImplementedError(
        "os.scandir is not available in the sandbox; use pokeet.walk() or pokeet.listdir()"
    )


_os.scandir = _scandir


# -- redirect open() ------------------------------------------------------
def _sandboxed_open(file, mode="r", *args, **kwargs):
    if isinstance(file, int):
        raise TypeError("sandbox files are opened by path, not by file descriptor")
    return SandboxFile(file, mode or "r")


_builtins.open = _sandboxed_open
_io.open = _sandboxed_open
"""#
}
