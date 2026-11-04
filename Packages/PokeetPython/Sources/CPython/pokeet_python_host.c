#include "pokeet_python_host.h"

#include <Python.h>
#include <stdlib.h>

static PokeetPyHost *g_host;
static int g_bootstrapped;

static PyObject *py_call(PyObject *self, PyObject *args) {
    const char *operation = NULL;
    const char *payload = NULL;
    if (!PyArg_ParseTuple(args, "ss", &operation, &payload)) return NULL;

    if (g_host == NULL || g_host->dispatch == NULL) {
        PyErr_SetString(PyExc_RuntimeError, "the sandbox filesystem is not available");
        return NULL;
    }

    char *error = NULL;
    char *response = g_host->dispatch(g_host->opaque, operation, payload, &error);
    if (response == NULL) {
        PyErr_SetString(PyExc_OSError, error != NULL ? error : "sandbox filesystem call failed");
        free(error);
        return NULL;
    }

    PyObject *result = PyUnicode_FromString(response);
    free(response);
    return result;
}

static PyMethodDef pokeet_methods[] = {
    {"call", py_call, METH_VARARGS, "Run a sandbox filesystem operation and return its JSON result."},
    {NULL, NULL, 0, NULL}
};

static struct PyModuleDef pokeet_module = {
    PyModuleDef_HEAD_INIT,
    "_pokeet",
    "Sandbox bridge owned by the host application.",
    -1,
    pokeet_methods,
    NULL, NULL, NULL, NULL
};

int pokeet_py_bootstrap(const char *prelude_source) {
    if (!Py_IsInitialized()) return -1;
    if (g_bootstrapped) return 0;

    PyGILState_STATE gil = PyGILState_Ensure();

    int ok = 1;
    PyObject *module = PyModule_Create(&pokeet_module);
    PyObject *sys = PyImport_ImportModule("sys");
    PyObject *modules = sys ? PyObject_GetAttrString(sys, "modules") : NULL;

    if (module == NULL || modules == NULL) {
        ok = 0;
    } else if (PyDict_SetItemString(modules, "_pokeet", module) < 0) {
        ok = 0;
    } else if (prelude_source != NULL) {
        PyObject *dict = PyModule_GetDict(module);
        PyObject *result = PyRun_StringFlags(prelude_source, Py_file_input, dict, dict, NULL);
        if (result == NULL) {
            PyErr_Print();
            ok = 0;
        } else {
            Py_DECREF(result);
        }
        // The prelude also answers to `pokeet`, which is what scripts import.
        if (ok) PyDict_SetItemString(modules, "pokeet", module);
    }

    Py_XDECREF(modules);
    Py_XDECREF(sys);
    Py_XDECREF(module);

    if (PyErr_Occurred()) PyErr_Clear();
    PyGILState_Release(gil);
    g_bootstrapped = ok;
    return ok ? 0 : -1;
}

void pokeet_py_install_host(PokeetPyHost *host) {
    g_host = host;
}

void pokeet_py_clear_host(void) {
    g_host = NULL;
}
