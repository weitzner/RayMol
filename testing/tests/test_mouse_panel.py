"""Unit tests for pymol.appkit_mouse_panel — headless, no PyMOL/AppKit required.

Tests the pure-Python logic: _build_mode_array, _code_for, CODE,
_SELECTION_MODE_NAMES. AppKit/objc/Foundation are stubbed before import.
"""

import os
import sys
import types
import unittest

# ---------------------------------------------------------------------------
# Stub out AppKit / objc / Foundation so the module can be imported headless
# ---------------------------------------------------------------------------

# Build a minimal NSColor mock that accepts the class-method call
class _NSColorMock:
    @staticmethod
    def colorWithCalibratedRed_green_blue_alpha_(*args):
        return None

_appkit_stub = types.ModuleType("AppKit")
_appkit_stub.NSColor = _NSColorMock
_appkit_stub.NSFont = types.SimpleNamespace(userFixedPitchFontOfSize_=lambda s: None)
_appkit_stub.NSButton = types.SimpleNamespace()
_appkit_stub.NSTextView = types.SimpleNamespace()
_appkit_stub.NSMutableAttributedString = types.SimpleNamespace()
_appkit_stub.NSAttributedString = types.SimpleNamespace()
_appkit_stub.NSFontAttributeName = "NSFontAttributeName"
_appkit_stub.NSForegroundColorAttributeName = "NSForegroundColorAttributeName"
_appkit_stub.NSBezelStyleSmallSquare = 0
_appkit_stub.NSViewWidthSizable = 1
_appkit_stub.NSViewHeightSizable = 2
_appkit_stub.NSRunLoopCommonModes = "common"
_appkit_stub.NSRunLoop = types.SimpleNamespace(
    currentRunLoop=lambda: types.SimpleNamespace(addTimer_forMode_=lambda *a: None)
)
_appkit_stub.NSTimer = types.SimpleNamespace()
_appkit_stub.NSMakeRect = lambda *a: a
# NSObject needs to be a real class for ObjC subclassing syntax
_appkit_stub.NSObject = type("NSObject", (), {})

_objc_stub = types.ModuleType("objc")

# objc.super needs to return something whose .init() works
class _ObjcSuperProxy:
    def __init__(self, *args):
        pass
    def init(self):
        return None

_objc_stub.super = _ObjcSuperProxy
_objc_stub.typedSelector = lambda sig: lambda fn: fn
_objc_stub.selector = lambda fn, signature=b"": fn

_foundation_stub = types.ModuleType("Foundation")

sys.modules["AppKit"] = _appkit_stub
sys.modules["objc"] = _objc_stub
sys.modules["Foundation"] = _foundation_stub

# Bootstrap pymol package stub
_MODULES_DIR = os.path.join(
    os.path.dirname(__file__), os.pardir, os.pardir, "modules"
)
_MODULES_DIR = os.path.normpath(_MODULES_DIR)

if "pymol" not in sys.modules or not hasattr(sys.modules["pymol"], "__path__"):
    _pymol_stub = types.ModuleType("pymol")
    _pymol_stub.__path__ = [os.path.join(_MODULES_DIR, "pymol")]
    _pymol_stub.__package__ = "pymol"
    sys.modules["pymol"] = _pymol_stub

from pymol.appkit_mouse_panel import (
    _build_mode_array,
    _code_for,
    CODE,
    _SELECTION_MODE_NAMES,
    _BUTTON_MOD_TO_INDEX,
    BLANK,
)


class TestBuildModeArray(unittest.TestCase):
    """Tests for _build_mode_array()."""

    def test_empty_mode_list(self):
        mode = _build_mode_array([])
        self.assertEqual(len(mode), 22)
        self.assertTrue(all(a == "none" for a in mode))

    def test_known_entries(self):
        mode_list = [
            ("l", "none", "Rota"),
            ("m", "none", "Move"),
            ("r", "none", "MovZ"),
            ("w", "none", "+/-"),
            ("double_left", "none", "Menu"),
            ("single_left", "none", "Sele"),
        ]
        mode = _build_mode_array(mode_list)
        self.assertEqual(mode[0], "rota")   # l,none
        self.assertEqual(mode[1], "move")   # m,none
        self.assertEqual(mode[2], "movz")   # r,none
        self.assertEqual(mode[12], "+/-")   # w,none
        self.assertEqual(mode[16], "menu")  # double_left,none
        self.assertEqual(mode[19], "sele")  # single_left,none
        self.assertEqual(mode[3], "none")   # unset

    def test_modifier_entries(self):
        mode_list = [
            ("l", "shft", "PkAt"),
            ("m", "ctrl", "PkBd"),
            ("r", "ctsh", "Orig"),
        ]
        mode = _build_mode_array(mode_list)
        self.assertEqual(mode[3], "pkat")   # l,shft
        self.assertEqual(mode[7], "pkbd")   # m,ctrl
        self.assertEqual(mode[11], "orig")  # r,ctsh

    def test_unknown_button_mod_ignored(self):
        mode_list = [("unknown_btn", "none", "Rota")]
        mode = _build_mode_array(mode_list)
        self.assertEqual(len(mode), 22)


class TestCodeFor(unittest.TestCase):
    """Tests for _code_for()."""

    def test_known_actions(self):
        self.assertEqual(_code_for("rota"), "Rota ")
        self.assertEqual(_code_for("move"), "Move ")
        self.assertEqual(_code_for("movz"), "MovZ ")
        self.assertEqual(_code_for("none"), "  -  ")
        self.assertEqual(_code_for("menu"), "Menu ")
        self.assertEqual(_code_for("sele"), "Sele ")

    def test_case_insensitive(self):
        self.assertEqual(_code_for("ROTA"), "Rota ")
        self.assertEqual(_code_for("Move"), "Move ")

    def test_unknown_action_padded(self):
        result = _code_for("xyz")
        self.assertEqual(len(result), 5)
        self.assertEqual(result, "xyz  ")

    def test_long_unknown_truncated(self):
        result = _code_for("verylongaction")
        self.assertEqual(len(result), 5)
        self.assertEqual(result, "veryl")


class TestCODEDict(unittest.TestCase):
    """Tests for the CODE constant."""

    EXPECTED_KEYS = {
        "rota", "move", "movz", "clip", "rotz", "clpn", "clpf",
        "lb", "mb", "rb", "+lb", "+mb", "+rb",
        "pkat", "pkbd", "rotf", "torf", "movf", "orig",
        "+lbx", "-lbx", "lbbx",
        "none", "cent", "pktb", "slab", "movs", "pk1",
        "mova", "menu", "sele",
        "+/-", "+box", "-box",
        "mvsz", "clik", "mvoz", "movo", "roto", "drgm",
        "rotv", "movv", "mvvz", "drgo", "mvfz", "mvaz",
        "rotl", "movl", "mvzl", "imsz", "imvz", "box", "irtz",
        "rotd", "movd", "mvdz",
    }

    def test_all_expected_keys_present(self):
        for key in self.EXPECTED_KEYS:
            self.assertIn(key, CODE, f"Missing CODE key: {key}")

    def test_all_values_are_5_chars(self):
        for key, val in CODE.items():
            self.assertEqual(len(val), 5, f"CODE[{key!r}] = {val!r} is not 5 chars")


class TestSelectionModeNames(unittest.TestCase):
    """Tests for _SELECTION_MODE_NAMES."""

    def test_has_7_entries(self):
        self.assertEqual(len(_SELECTION_MODE_NAMES), 7)

    def test_expected_entries(self):
        expected = ["Atoms", "Residues", "Chains", "Segments", "Objects", "Molecules", "C-alphas"]
        self.assertEqual(_SELECTION_MODE_NAMES, expected)


class TestButtonModToIndex(unittest.TestCase):
    """Tests for _BUTTON_MOD_TO_INDEX mapping."""

    def test_has_22_entries(self):
        self.assertEqual(len(_BUTTON_MOD_TO_INDEX), 22)

    def test_indices_cover_0_to_21(self):
        indices = set(_BUTTON_MOD_TO_INDEX.values())
        self.assertEqual(indices, set(range(22)))


if __name__ == "__main__":
    unittest.main()
