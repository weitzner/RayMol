"""Unit tests for pymol.appkit_object_panel — headless, no PyMOL/AppKit.

Covers the pure action-dispatch logic behind the object panel's "A" menu:
_find_action_key (nested-submenu title lookup) and _run_action_command
(title -> cmd.* call), plus structural invariants of the menu-option tables.
AppKit/objc/Foundation are stubbed permissively before import.
"""

import os
import sys
import types
import unittest
from unittest.mock import MagicMock


class _PermissiveModule(types.ModuleType):
    """A module whose unknown attributes auto-vivify as MagicMocks."""

    def __getattr__(self, name):
        mock = MagicMock(name="AppKit.%s" % name)
        setattr(self, name, mock)
        return mock


def _install_appkit_stubs():
    appkit = _PermissiveModule("AppKit")
    # NSObject must be a real class so `class X(AppKit.NSObject)` works.
    appkit.NSObject = type("NSObject", (), {})

    objc = _PermissiveModule("objc")

    class _ObjcSuperProxy:
        def __init__(self, *a):
            pass

        def init(self):
            return None

    objc.super = _ObjcSuperProxy
    objc.typedSelector = lambda sig: (lambda fn: fn)
    objc.selector = lambda fn, signature=b"": fn

    foundation = _PermissiveModule("Foundation")

    sys.modules["AppKit"] = appkit
    sys.modules["objc"] = objc
    sys.modules["Foundation"] = foundation


_install_appkit_stubs()

_MODULES_DIR = os.path.normpath(
    os.path.join(os.path.dirname(__file__), os.pardir, os.pardir, "modules")
)
if "pymol" not in sys.modules or not hasattr(sys.modules["pymol"], "__path__"):
    _pymol_stub = types.ModuleType("pymol")
    _pymol_stub.__path__ = [os.path.join(_MODULES_DIR, "pymol")]
    _pymol_stub.__package__ = "pymol"
    sys.modules["pymol"] = _pymol_stub

from pymol import appkit_object_panel as op


class RecordingCmd:
    """Any attribute is a callable that records (name, args, kwargs)."""

    def __init__(self):
        self.calls = []

    def __getattr__(self, name):
        def _rec(*args, **kwargs):
            self.calls.append((name, args, kwargs))
        return _rec


class FindActionKeyTest(unittest.TestCase):
    def test_top_level_title(self):
        self.assertEqual(op._find_action_key("Zoom", op._ACTION_OPTIONS), "zoom")
        self.assertEqual(op._find_action_key("Clean", op._ACTION_OPTIONS), "clean")

    def test_nested_submenu_titles(self):
        self.assertEqual(
            op._find_action_key("classified", op._ACTION_OPTIONS),
            "preset_classified")
        self.assertEqual(
            op._find_action_key("polar contacts (within)", op._ACTION_OPTIONS),
            "find_polar_within")
        self.assertEqual(op._find_action_key("add", op._ACTION_OPTIONS), "h_add")

    def test_separator_and_unknown_return_none(self):
        self.assertIsNone(op._find_action_key("---", op._ACTION_OPTIONS))
        self.assertIsNone(op._find_action_key("no-such-title", op._ACTION_OPTIONS))


class RunActionCommandTest(unittest.TestCase):
    def _dispatch(self, title):
        cmd = RecordingCmd()
        op._run_action_command(cmd, "obj1", title)
        return cmd.calls

    def test_view_transform_actions(self):
        self.assertEqual(self._dispatch("Zoom"),
                         [("zoom", ("obj1",), {"animate": -1})])
        self.assertEqual(self._dispatch("Orient"),
                         [("orient", ("obj1",), {"animate": -1})])
        self.assertEqual(self._dispatch("Center"),
                         [("center", ("obj1",), {"animate": -1})])
        self.assertEqual(self._dispatch("Origin"),
                         [("origin", ("obj1",), {})])

    def test_clean_and_dss(self):
        self.assertEqual(self._dispatch("Clean"), [("clean", ("obj1",), {})])
        self.assertEqual(self._dispatch("Assign Sec. Struc."),
                         [("dss", ("obj1",), {})])

    def test_unknown_title_dispatches_nothing(self):
        self.assertEqual(self._dispatch("no-such-title"), [])


class OptionTableInvariantsTest(unittest.TestCase):
    def _leaf_keys(self, options):
        keys = []
        for item in options:
            if item[0] == "---":
                continue
            if len(item) > 2 and item[2] is not None:
                keys.extend(self._leaf_keys(item[2]))
            elif item[1] is not None:
                keys.append(item[1])
        return keys

    def test_action_keys_are_unique(self):
        keys = self._leaf_keys(op._ACTION_OPTIONS)
        self.assertEqual(len(keys), len(set(keys)), "duplicate action keys")

    def test_every_action_leaf_is_resolvable(self):
        # Every leaf title must resolve to a non-None key via _find_action_key,
        # so no menu entry can silently no-op in _run_action_command.
        def walk(options):
            for item in options:
                if item[0] == "---":
                    continue
                if len(item) > 2 and item[2] is not None:
                    walk(item[2])
                elif item[1] is not None:
                    self.assertIsNotNone(
                        op._find_action_key(item[0], op._ACTION_OPTIONS),
                        "unresolvable action title: %r" % item[0])
        walk(op._ACTION_OPTIONS)

    def test_show_hide_options_key_equals_title(self):
        for item in op._SHOW_HIDE_OPTIONS:
            if item[0] == "---":
                continue
            self.assertEqual(item[0], item[1])

    def test_label_options_shape(self):
        # First entry clears labels (empty expr); others are non-empty exprs.
        self.assertEqual(op._LABEL_OPTIONS[0], ("None", ""))
        for title, expr in op._LABEL_OPTIONS:
            if title == "---":
                continue
            self.assertIsInstance(expr, str)


if __name__ == "__main__":
    unittest.main()
