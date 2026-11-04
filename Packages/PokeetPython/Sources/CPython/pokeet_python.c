// Embedding glue for the CPython spike.
//
// Everything here exists to answer one question: can CPython be held to the same
// contract QuickJS honours — a hard wall clock, a hard memory ceiling, and output
// the agent can read back. The answers are the interrupt flag (CPython has no
// interrupt handler, so we raise from a pending call) and a counting allocator
// (CPython has no heap limit, so we refuse the allocation instead).

#include "pokeet_python.h"

#include <Python.h>
#include <stdlib.h>
#include <string.h>
#include <pythread.h>
#include <stdio.h>

// 16 bytes of bookkeeping in front of every block keeps returned pointers aligned.
#define POKEET_HEADER 16

static size_t g_cap;      // bytes, 0 means unlimited
static size_t g_live;     // bytes currently held
static int g_interrupt;   // set by the watchdog before it raises
static int g_started;

// ---------------------------------------------------------------- allocator

static void *cap_malloc(void *ctx, size_t size) {
    size_t total = size + POKEET_HEADER;
    if (g_cap && g_live + total > g_cap) return NULL;
    void *block = malloc(total);
    if (block == NULL) return NULL;
    *(size_t *)block = total;
    g_live += total;
    return (char *)block + POKEET_HEADER;
}

static void cap_free(void *ctx, void *ptr) {
    if (ptr == NULL) return;
    char *block = (char *)ptr - POKEET_HEADER;
    size_t total = *(size_t *)block;
    g_live = g_live > total ? g_live - total : 0;
    free(block);
}

static void *cap_calloc(void *ctx, size_t nelem, size_t elsize) {
    size_t size = nelem * elsize;
    if (elsize && size / elsize != nelem) return NULL;
    void *block = cap_malloc(ctx, size);
    if (block) memset(block, 0, size);
    return block;
}

static void *cap_realloc(void *ctx, void *ptr, size_t size) {
    if (ptr == NULL) return cap_malloc(ctx, size);
    char *block = (char *)ptr - POKEET_HEADER;
    size_t old = *(size_t *)block;
    size_t total = size + POKEET_HEADER;
    if (g_cap && g_live - old + total > g_cap) return NULL;
    char *grown = realloc(block, total);
    if (grown == NULL) return NULL;
    *(size_t *)grown = total;
    g_live = g_live - old + total;
    return grown + POKEET_HEADER;
}

// ---------------------------------------------------------------- interrupt

static unsigned long g_run_ident;   // OS thread id of the thread running Python

int pokeet_py_interrupted(void) {
    return g_interrupt;
}

void pokeet_py_interrupt(void) {
    if (!g_started || g_run_ident == 0) return;
    g_interrupt = 1;

    // PyThreadState_SetAsyncExc needs a thread state in TLS to find the interpreter,
    // so the watchdog must attach first. Attaching waits for the GIL, which a
    // bytecode loop releases every switch interval — that is what makes this work
    // at all, and it is why a long C call inside the script stays uninterruptible.
    PyGILState_STATE gil = PyGILState_Ensure();
    PyThreadState_SetAsyncExc(g_run_ident, PyExc_KeyboardInterrupt);
    PyGILState_Release(gil);
}

// ---------------------------------------------------------------- lifecycle

int pokeet_py_start_with_home(const char *home) {
    if (g_started) return 0;

    PyMemAllocatorEx allocator;
    allocator.ctx = NULL;
    allocator.malloc = cap_malloc;
    allocator.calloc = cap_calloc;
    allocator.realloc = cap_realloc;
    allocator.free = cap_free;
    // Must happen before Py_Initialize: the object and memory domains are built on top.
    PyMem_SetAllocator(PYMEM_DOMAIN_RAW, &allocator);

    // Isolated config: no environment, no user site, no argv parsing. Mirrors what
    // Python-Apple-support's own testbed does, and is what makes a cross-compiled
    // interpreter honour an explicit home instead of its builder's prefix.
    PyPreConfig preconfig;
    PyPreConfig_InitIsolatedConfig(&preconfig);
    preconfig.utf8_mode = 1;
    if (PyStatus_Exception(Py_PreInitialize(&preconfig))) return -1;

    PyConfig config;
    PyConfig_InitIsolatedConfig(&config);
    config.install_signal_handlers = 0;   // the watchdog owns the clock
    config.write_bytecode = 0;            // the stdlib may live in a read-only bundle
    config.buffered_stdio = 0;

    if (home != NULL) {
        wchar_t *wide = Py_DecodeLocale(home, NULL);
        if (wide == NULL) {
            PyConfig_Clear(&config);
            return -1;
        }
        PyStatus status = PyConfig_SetString(&config, &config.home, wide);
        PyMem_RawFree(wide);
        if (PyStatus_Exception(status)) {
            PyConfig_Clear(&config);
            return -1;
        }
    }

    PyStatus status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status) || !Py_IsInitialized()) return -1;

    // The initialising thread must not keep the GIL, or every run deadlocks.
    PyEval_SaveThread();
    g_started = 1;
    return 0;
}

int pokeet_py_start(void) {
    return pokeet_py_start_with_home(NULL);
}

size_t pokeet_py_allocated(void) {
    return g_live;
}

void pokeet_py_free(char *pointer) {
    free(pointer);
}

// ---------------------------------------------------------------- helpers

static char *copy_string(const char *text, Py_ssize_t length) {
    char *out = malloc((size_t)length + 1);
    if (out == NULL) return NULL;
    memcpy(out, text, (size_t)length);
    out[length] = '\0';
    return out;
}

static char *drain_string_io(PyObject *stream) {
    if (stream == NULL) return NULL;
    PyObject *value = PyObject_CallMethod(stream, "getvalue", NULL);
    if (value == NULL) {
        PyErr_Clear();
        return NULL;
    }
    Py_ssize_t length = 0;
    const char *text = PyUnicode_AsUTF8AndSize(value, &length);
    char *out = text ? copy_string(text, length) : NULL;
    Py_DECREF(value);
    return out;
}

/// Builds a fresh `__main__` namespace so runs do not share state.
static PyObject *make_namespace(void) {
    PyObject *dict = PyDict_New();
    if (dict == NULL) return NULL;

    PyObject *name = PyUnicode_FromString("__main__");
    if (name && PyDict_SetItemString(dict, "__name__", name) < 0) {
        Py_XDECREF(name);
        Py_DECREF(dict);
        return NULL;
    }
    Py_XDECREF(name);

    PyObject *builtins = PyEval_GetBuiltins();
    if (builtins && PyDict_SetItemString(dict, "__builtins__", builtins) < 0) {
        Py_DECREF(dict);
        return NULL;
    }
    return dict;
}

// ---------------------------------------------------------------- run

int pokeet_py_run(
    const char *source,
    const char *filename,
    size_t budgetBytes,
    char **out_stdout,
    char **out_stderr,
    int *out_termination,
    char **out_errorType,
    char **out_errorMessage
) {
    if (out_stdout) *out_stdout = NULL;
    if (out_stderr) *out_stderr = NULL;
    if (out_errorType) *out_errorType = NULL;
    if (out_errorMessage) *out_errorMessage = NULL;
    if (out_termination) *out_termination = POKEET_PY_ERROR;

    if (pokeet_py_start() != 0) return -1;

    // Budget is measured from whatever the interpreter already holds, so a run's
    // ceiling does not depend on how much earlier runs left behind.
    g_cap = budgetBytes ? g_live + budgetBytes : 0;
    g_interrupt = 0;

    PyGILState_STATE gil = PyGILState_Ensure();
    g_run_ident = (unsigned long)PyThread_get_thread_ident();

    PyObject *io = PyImport_ImportModule("io");
    PyObject *capturedOut = io ? PyObject_CallMethod(io, "StringIO", NULL) : NULL;
    PyObject *capturedErr = io ? PyObject_CallMethod(io, "StringIO", NULL) : NULL;

    PyObject *savedOut = PySys_GetObject("stdout");   // borrowed
    PyObject *savedErr = PySys_GetObject("stderr");   // borrowed
    Py_XINCREF(savedOut);
    Py_XINCREF(savedErr);

    if (capturedOut) PySys_SetObject("stdout", capturedOut);
    if (capturedErr) PySys_SetObject("stderr", capturedErr);

    PyObject *dict = make_namespace();
    PyObject *result = NULL;
    if (dict) {
        PyObject *name = PyUnicode_FromString(filename ? filename : "<script>");
        result = PyRun_StringFlags(source, Py_file_input, dict, dict, NULL);
        Py_XDECREF(name);
    }

    int termination = POKEET_PY_OK;
    char *errorType = NULL;
    char *errorMessage = NULL;

    if (result == NULL) {
        if (PyErr_ExceptionMatches(PyExc_MemoryError)) {
            termination = POKEET_PY_OUT_OF_MEMORY;
        } else if (g_interrupt && PyErr_ExceptionMatches(PyExc_KeyboardInterrupt)) {
            termination = POKEET_PY_TIMED_OUT;
        } else {
            termination = POKEET_PY_ERROR;
        }

        PyObject *type = NULL, *value = NULL, *traceback = NULL;
        PyErr_Fetch(&type, &value, &traceback);
        PyErr_NormalizeException(&type, &value, &traceback);
        if (type) {
            PyObject *typeName = PyObject_GetAttrString(type, "__name__");
            if (typeName) {
                Py_ssize_t length = 0;
                const char *text = PyUnicode_AsUTF8AndSize(typeName, &length);
                if (text) errorType = copy_string(text, length);
                Py_DECREF(typeName);
            }
        }
        if (value) {
            PyObject *message = PyObject_Str(value);
            if (message) {
                Py_ssize_t length = 0;
                const char *text = PyUnicode_AsUTF8AndSize(message, &length);
                if (text) errorMessage = copy_string(text, length);
                Py_DECREF(message);
            }
        }
        // Reprint into the captured stderr so the agent gets a traceback, not a summary.
        PyErr_Restore(type, value, traceback);
        PyErr_PrintEx(0);
    } else {
        Py_DECREF(result);
    }

    if (out_stdout) *out_stdout = drain_string_io(capturedOut);
    if (out_stderr) *out_stderr = drain_string_io(capturedErr);
    if (out_termination) *out_termination = termination;
    if (out_errorType) *out_errorType = errorType;
    if (out_errorMessage) *out_errorMessage = errorMessage;

    // Nothing outstanding is expected; clear rather than corrupt the next run.
    if (PyErr_Occurred()) PyErr_Clear();
    PySys_SetObject("stdout", savedOut);
    PySys_SetObject("stderr", savedErr);

    Py_XDECREF(savedOut);
    Py_XDECREF(savedErr);
    Py_XDECREF(capturedOut);
    Py_XDECREF(capturedErr);
    Py_XDECREF(io);
    Py_XDECREF(dict);

    g_cap = 0;
    g_run_ident = 0;
    PyGILState_Release(gil);
    return 0;
}
