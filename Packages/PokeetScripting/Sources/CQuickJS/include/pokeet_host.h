#ifndef POKEET_HOST_H
#define POKEET_HOST_H

#include "quickjs.h"

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Bridge between QuickJS and the host application.
 *
 * The host installs a single C function, __hostCall(op, argsJSON), which every
 * sandboxed API in the JavaScript prelude funnels through. Keeping the C surface
 * to one dispatcher keeps the binding small and moves all policy into Swift.
 *
 * dispatch() must return a malloc'd UTF-8 JSON string (the caller frees it), or
 * NULL with a malloc'd error message in *error_out. Returning NULL without an
 * error message raises a generic error in JavaScript.
 */
typedef char *(*PokeetHostDispatch)(
    void *opaque,
    const char *op,
    const char *args_json,
    char **error_out
);

typedef struct PokeetHost {
    void *opaque;
    PokeetHostDispatch dispatch;
    /* CLOCK_MONOTONIC deadline in milliseconds. 0 disables the wall-clock limit. */
    double deadline_ms;
    /* Optional pointer polled by the interrupt handler for cooperative cancellation. */
    volatile int *cancelled;
} PokeetHost;

/* Installs __hostCall and the interrupt handler on ctx. */
void pokeet_install_host(JSContext *ctx, PokeetHost *host);

/* Exposed for tests: milliseconds on the CLOCK_MONOTONIC clock. */
double pokeet_now_ms(void);

#ifdef __cplusplus
}
#endif

#endif /* POKEET_HOST_H */
