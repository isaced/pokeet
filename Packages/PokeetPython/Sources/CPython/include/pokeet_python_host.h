#ifndef POKEET_PYTHON_HOST_H
#define POKEET_PYTHON_HOST_H

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Bridge between the embedded interpreter and the host filesystem.
 *
 * Same shape as the QuickJS host (see CQuickJS/pokeet_host.h): one C dispatcher,
 * every sandboxed file operation funnelled through it, all policy in Swift. The
 * dispatcher must return a malloc'd UTF-8 JSON string (the caller frees it), or
 * NULL with a malloc'd message in *error_out, which surfaces in Python as OSError.
 */
typedef char *(*PokeetPyDispatch)(
    void *opaque,
    const char *operation,
    const char *args_json,
    char **error_out
);

typedef struct PokeetPyHost {
    void *opaque;
    PokeetPyDispatch dispatch;
} PokeetPyHost;

/* Installs the filesystem behind `_pokeet`, which runs the Python prelude once. */
int pokeet_py_bootstrap(const char *prelude_source);

/* Points the installed bridge at this run's filesystem. Call before each run. */
void pokeet_py_install_host(PokeetPyHost *host);

/* Detaches the bridge, so a stale pointer is never called after a run. */
void pokeet_py_clear_host(void);

#ifdef __cplusplus
}
#endif

#endif
