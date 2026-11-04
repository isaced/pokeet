# PokeetPython

The second `ScriptRuntime`: CPython 3.12, held to the same sandbox contract as QuickJS.
It ships — `AppEnvironment` registers it whenever the stdlib made it into the bundle.

What a script can do with it is documented in [docs/scripts.md](../../docs/scripts.md)
and [docs/scripts-network.md](../../docs/scripts-network.md). This file keeps the
engineering notes that do not fit there: how the interpreter is embedded, and what the
limits cost.

## Run it

```sh
scripts/fetch-python.sh
swift test --package-path Packages/PokeetPython \
  -Xlinker "$(brew --prefix python@3.12)/Frameworks/Python.framework/Versions/3.12/lib/libpython3.12.dylib"
```

The package links no interpreter: the app embeds `Vendor/Python.xcframework` through
`project.yml`, and the test bundle takes the host dylib with `-Xlinker`. That keeps one
manifest working for both, which a platform check cannot do — Xcode does not pass
`PLATFORM_NAME` to package evaluation.

[pas]: https://github.com/beeware/Python-Apple-support

## What works

`PythonRuntime` conforms to `ScriptRuntime`, so it plugs into `ScriptRuntimes` and
`run_script` unchanged — including the `runtime: "python"` argument and the `script.py`
filename branch that already existed in `RunScriptTool`.

The Python side of the sandbox lives in `Resources/python-prelude.py`: `open`, the read
half of `os`, `urllib.request` and the `pokeet` helpers.

- **Output capture** — `sys.stdout`/`stderr` are swapped for `StringIO` per run and
  drained afterwards.
- **Tracebacks** — an uncaught exception is reprinted into the captured stderr, so the
  agent reads the same detail it gets from the JavaScript runtime.
- **A hard memory ceiling** — CPython has no heap limit, so a counting allocator is
  installed on `PYMEM_DOMAIN_RAW` before `Py_Initialize`. The budget is measured from
  what the interpreter already holds, so it is per-run rather than global.
- **A hard wall clock** — see below.
- **Recovery** — a run that times out or exhausts memory leaves the interpreter usable;
  nothing is torn down between runs.

## The wall clock, and why the obvious approach fails

QuickJS exposes `JS_SetInterruptHandler`. CPython has no equivalent, and the two
mechanisms that look equivalent do not work:

| Attempt | Result |
|---|---|
| `Py_AddPendingCall` from a watchdog thread | returns 0, the callback never runs — pending calls are only serviced by the interpreter's *own* main thread |
| the same, after initialising the interpreter on a worker thread | still never runs |
| `PyThreadState_SetAsyncExc` from a bare thread | segfault: the call resolves the interpreter from thread-local state, and a bare thread has none |
| `_PyThreadState_SetAsyncExc(interp, …)` | not exported from `libpython` |

What does work is a two-step: the watchdog takes a thread state with `PyGILState_Ensure`
(so the interpreter lookup succeeds) and passes `PyThread_get_thread_ident()`, **not**
`PyThreadState_GetID()`, as the target. `PyGILState_Ensure` blocks until the GIL is
free — which is fine, because a bytecode loop releases it every switch interval. That
last point is also the limitation, below.

The exception is asynchronous and therefore one-shot, so the Swift watchdog repeats every
250 ms after the deadline: a script that catches `KeyboardInterrupt` in a loop would
otherwise outlive its budget.

## Known limits

- **A long C call inside the script is uninterruptible.** Regex backtracking, a huge
  `zlib.decompress` or anything else that holds the GIL inside C will not reach a
  bytecode boundary, so the watchdog waits. Bounding those needs process isolation,
  which iOS does not offer.
- **Bytes.** 8.6 MB compressed after trimming, against QuickJS's 2.8 MB — see
  [What it costs](#what-it-costs).
- **Version coupling.** The interrupt dance depends on CPython internals that have
  shifted across 3.9 → 3.13 (`PyThreadState_SetAsyncExc`'s argument changed meaning).
  Pin the interpreter version and cover it with the test above.

## What it costs

Measured, not estimated — device slice, Python-Apple-support 3.12-b13:

| | Unpacked | Zipped (App Store delta) |
|---|---|---|
| `Python.framework` | 8.0 MB | |
| Pure-Python stdlib | 46 MB | |
| Extension modules (66 `.so`) | 15 MB | |
| **Everything, untrimmed** | **69 MB** | **19 MB** |
| **Trimmed** (no `test/`, `idlelib`, `ensurepip`, `lib2to3`, `tkinter`, `_test*`) | **32 MB** | **8.6 MB** |

`test/` alone is 32 MB of the stdlib, so most of the savings are free. The remaining
cost is the interpreter plus the extension modules the app actually needs.

## The filesystem bridge

`builtins.open` and `io.open` are redirected to the workspace, so ordinary file code
works and `pathlib` comes along for free (`Path.read_text` goes through `io.open`).

| Call | Behaviour |
|---|---|
| `open(path)` | reads through `ScriptFileSystem.read`, so `maxReadBytes` applies |
| `open(path, 'w')` | buffers, hands over on `close`/`flush` → one `FileProposal` |
| `open(path, 'a')` | read-then-write, so staged content of the same run is visible |
| `open(path, 'rb')` | the UTF-8 bytes of the stored text, so `shutil.copyfile` works on source files |
| `import pokeet` | `read`, `write`, `append`, `listdir`, `walk`, `exists`, `info` |

Files are always relative to the project root; `../x` and absolute paths are rejected
at **open**, not at close, so a handle that is never closed cannot silently swallow a
write. Nothing reaches the project until the proposal is approved — the same review
path the JavaScript runtime and the file tools use.

Deliberately **not** redirected: `os.listdir`, `os.path.exists`, `os.scandir`, `os.stat`,
`glob`. Monkeys-patching `os` breaks the import machinery, which has to see the real
stdlib on disk. Use the `pokeet` helpers instead, and expect `glob` to raise.

## Running on iOS

Verified in the simulator: `print`, a runaway loop interrupted at its deadline, a
refused 200 MB allocation, `import json, re, collections`, and the whole filesystem
bridge — `open`, write, append, `listdir`, `info`, `pathlib` — behave as they do on
macOS.

Three things only show up on iOS:

- **The stdlib is not inside the framework.** It ships separately (the
  `Python.xcframework/lib/python3.12` tree) and must be placed in the app bundle, then
  passed to `pokeet_py_start_with_home`.
- **`PYTHONHOME` is ignored.** The interpreter is cross-compiled and reports the
  builder's prefix (`/Users/runner/work/...`). The home has to be set through
  `PyConfig`, and only an *isolated* config honours it — `PyConfig_InitPythonConfig`
  silently keeps the compiled prefix.
- **`simctl spawn` does not forward the environment**, so the probe takes the home as
  an argument. Worth knowing before debugging a path that looks correct.

## Sandbox posture

No shell, no package manager, no socket: `ctypes`, `socket`, `ssl`, `http`, `asyncio` and
`urllib.request` are removed from the staged stdlib, so the only way out is the host
bridge. Scripts cannot write to the workspace except as reviewable proposals.

`urllib.request` is re-supplied by the prelude on top of `NetworkClient`, which is also
what `http_request` uses — one policy, one implementation.
