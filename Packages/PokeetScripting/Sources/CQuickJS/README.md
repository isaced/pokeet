# QuickJS-NG (vendored)

Sandboxed JavaScript engine for Pokeet's `run_script` tool.

- Upstream: https://github.com/quickjs-ng/quickjs
- Pinned commit: `e22ce4d` ("Clear Array.find value ownership after release (#1826)")
- License: MIT (see `LICENSE`)

Only the engine sources are vendored — no CLI, no `quickjs-libc`, no I/O or
network modules. `pokeet_host.c` is ours: it exposes a single
`__hostCall(op, argsJSON)` bridge function and installs the interrupt handler
that enforces the wall-clock deadline and cancellation flag.

## Why not JavaScriptCore

`JavaScriptCore.framework` has no public execution-time or memory limit
(`JSContextGroupSetExecutionTimeLimit` is SPI), so a runaway script would pin a
thread until the app is killed. QuickJS exposes `JS_SetInterruptHandler`,
`JS_SetMemoryLimit` and `JS_SetMaxStackSize` in its public API, needs no JIT
entitlement, and is an interpreter we can compile into the app.

## Updating

1. Check out the desired upstream commit.
2. Copy `dtoa.c`, `libregexp.c`, `libunicode.c`, `quickjs.c` to this directory.
3. Copy the headers they include (`quickjs.h`, `quickjs-atom.h`, `quickjs-opcode.h`,
   `quickjs-c-atomics.h`, `cutils.h`, `dtoa.h`, `list.h`, `libregexp.h`,
   `libregexp-opcode.h`, `libunicode.h`, `libunicode-table.h`,
   `builtin-array-fromasync.h`, `builtin-iterator-zip*.h`) into `include/`.
4. Update the pinned commit above and run `swift test --package-path Packages/PokeetScripting`.

Do not add `quickjs-libc.c`: file, process and network access must stay out of the sandbox.
