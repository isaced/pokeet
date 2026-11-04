#ifndef POKEET_CPYTHON_H
#define POKEET_CPYTHON_H

#include <stddef.h>

/// How a run ended. Mirrors PokeetCore's ScriptTermination on the Swift side.
enum pokeet_py_termination {
    POKEET_PY_OK = 0,
    POKEET_PY_ERROR = 1,
    POKEET_PY_TIMED_OUT = 2,
    POKEET_PY_OUT_OF_MEMORY = 3
};

/// Starts the interpreter once. Safe to call repeatedly.
/// `home` is the directory holding `lib/python3.x` (the bundled stdlib); pass NULL
/// to use the interpreter's compiled-in prefix, which only works on a dev machine.
/// Returns 0 on success, negative on failure.
int pokeet_py_start_with_home(const char *home);

/// Convenience wrapper: starts with the compiled-in prefix.
int pokeet_py_start(void);

/// Bytes currently held by the interpreter's own allocator.
size_t pokeet_py_allocated(void);

/// Runs `source` with a memory budget of `baseline + budgetBytes`.
/// On success, `*out_stdout` and `*out_stderr` are malloc'd copies the caller
/// must release with pokeet_py_free.
int pokeet_py_run(
    const char *source,
    const char *filename,
    size_t budgetBytes,
    char **out_stdout,
    char **out_stderr,
    int *out_termination,
    char **out_errorType,
    char **out_errorMessage
);

/// Raises KeyboardInterrupt at the interpreter's next bytecode boundary.
/// Safe to call from another thread: the watchdog uses it to enforce the
/// wall-clock budget, because CPython has no interrupt handler like QuickJS.
void pokeet_py_interrupt(void);

void pokeet_py_free(char *pointer);

#endif
