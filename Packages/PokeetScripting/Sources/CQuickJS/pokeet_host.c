#include "pokeet_host.h"

#include <stdlib.h>
#include <string.h>
#include <time.h>

double pokeet_now_ms(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        return 0.0;
    }
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
}

static int pokeet_interrupt(JSContext *ctx, void *opaque) {
    PokeetHost *host = (PokeetHost *)opaque;
    if (host == NULL) {
        return 0;
    }
    if (host->cancelled != NULL && *host->cancelled) {
        return 1;
    }
    if (host->deadline_ms > 0.0 && pokeet_now_ms() >= host->deadline_ms) {
        return 1;
    }
    (void)ctx;
    return 0;
}

static JSValue js_host_call(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;

    PokeetHost *host = (PokeetHost *)JS_GetContextOpaque(ctx);
    if (host == NULL || host->dispatch == NULL) {
        return JS_ThrowInternalError(ctx, "host bridge is not installed");
    }

    const char *op = NULL;
    const char *args = NULL;
    JSValue result = JS_UNDEFINED;

    if (argc < 1) {
        return JS_ThrowTypeError(ctx, "__hostCall requires an operation name");
    }
    op = JS_ToCString(ctx, argv[0]);
    if (op == NULL) {
        return JS_EXCEPTION;
    }
    if (argc > 1 && !JS_IsUndefined(argv[1]) && !JS_IsNull(argv[1])) {
        args = JS_ToCString(ctx, argv[1]);
        if (args == NULL) {
            JS_FreeCString(ctx, op);
            return JS_EXCEPTION;
        }
    }

    char *error = NULL;
    char *payload = host->dispatch(host->opaque, op, args ? args : "{}", &error);

    JS_FreeCString(ctx, op);
    if (args != NULL) {
        JS_FreeCString(ctx, args);
    }

    if (payload == NULL) {
        if (error != NULL) {
            result = JS_ThrowPlainError(ctx, "%s", error);
            free(error);
        } else {
            result = JS_ThrowInternalError(ctx, "host operation failed");
        }
        return result;
    }

    if (error != NULL) {
        free(error);
    }

    result = JS_NewString(ctx, payload);
    free(payload);
    return result;
}

void pokeet_install_host(JSContext *ctx, PokeetHost *host) {
    JS_SetContextOpaque(ctx, host);

    JSValue global = JS_GetGlobalObject(ctx);
    JS_SetPropertyStr(ctx, global, "__hostCall", JS_NewCFunction(ctx, js_host_call, "__hostCall", 2));
    JS_FreeValue(ctx, global);

    JSRuntime *rt = JS_GetRuntime(ctx);
    JS_SetInterruptHandler(rt, pokeet_interrupt, host);
}
