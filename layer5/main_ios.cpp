/*
 * main_ios.cpp — Stubs for iOS builds where main.cpp/main_appkit.mm are
 * excluded. Provides:
 *   - _gScaleFactor global
 *   - MainAsPyList / MainFromPyList / MainSavingUnderWhileIdle stubs
 */

#if defined(_PYMOL_IOS) || defined(_PYMOL_METAL_ONLY)

#include "os_python.h"
#include "PyMOLGlobals.h"

int _gScaleFactor = 1;

int MainSavingUnderWhileIdle(void) { return 0; }

PyObject *MainAsPyList(PyMOLGlobals *G) {
  Py_RETURN_NONE;
}

int MainFromPyList(PyMOLGlobals *G, PyObject *list) {
  return 1; /* success (no-op) */
}

#endif /* _PYMOL_IOS */
