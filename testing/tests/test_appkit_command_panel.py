"""Unit tests for pymol.appkit_command_panel — headless, no PyMOL/AppKit.

Covers _get_view_to_clipboard: it formats cmd.get_view()'s 18 floats into a
`cmd.set_view([...])` snippet and writes it to the general pasteboard. The
pasteboard is a permissive AppKit mock; `_cmd` is a fake with get_view().
"""

import os
import sys
import types
import unittest
from unittest.mock import MagicMock


class _PermissiveModule(types.ModuleType):
    def __getattr__(self, name):
        mock = MagicMock(name="AppKit.%s" % name)
        setattr(self, name, mock)
        return mock


def _install_appkit_stubs():
    appkit = _PermissiveModule("AppKit")
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
    sys.modules["AppKit"] = appkit
    sys.modules["objc"] = objc
    sys.modules["Foundation"] = _PermissiveModule("Foundation")


_install_appkit_stubs()

_MODULES_DIR = os.path.normpath(
    os.path.join(os.path.dirname(__file__), os.pardir, os.pardir, "modules")
)
if "pymol" not in sys.modules or not hasattr(sys.modules["pymol"], "__path__"):
    _pymol_stub = types.ModuleType("pymol")
    _pymol_stub.__path__ = [os.path.join(_MODULES_DIR, "pymol")]
    _pymol_stub.__package__ = "pymol"
    sys.modules["pymol"] = _pymol_stub

from pymol import appkit_command_panel as cp
import AppKit


class FakeCmd:
    def __init__(self, view=None, raises=False):
        self._view = view
        self._raises = raises

    def get_view(self):
        if self._raises:
            raise RuntimeError("no view")
        return self._view


class GetViewToClipboardTest(unittest.TestCase):
    def setUp(self):
        cp._log_text_view = None   # so _append_log() is a no-op
        # Reset the pasteboard mock between tests.
        AppKit.NSPasteboard = MagicMock(name="AppKit.NSPasteboard")

    def _pasteboard_text(self):
        pb = AppKit.NSPasteboard.generalPasteboard.return_value
        if not pb.setString_forType_.called:
            return None
        return pb.setString_forType_.call_args.args[0]

    def test_formats_view_as_set_view_snippet(self):
        view = tuple(float(i) for i in range(18))
        cp._cmd = FakeCmd(view=view)
        cp._get_view_to_clipboard()
        text = self._pasteboard_text()
        self.assertIsNotNone(text)
        self.assertTrue(text.startswith("cmd.set_view([\\\n"))
        self.assertTrue(text.rstrip().endswith("])"))
        # 6 rows of 3 floats each = the 18-element view matrix.
        body_rows = [ln for ln in text.splitlines() if "," in ln and "set_view" not in ln]
        self.assertEqual(len(body_rows), 6)
        self.assertIn("0.000000000", text)   # %14.9f formatting
        self.assertIn("17.000000000", text)

    def test_clears_pasteboard_before_writing(self):
        cp._cmd = FakeCmd(view=tuple(0.0 for _ in range(18)))
        cp._get_view_to_clipboard()
        pb = AppKit.NSPasteboard.generalPasteboard.return_value
        self.assertTrue(pb.clearContents.called)

    def test_get_view_error_does_not_write_clipboard(self):
        cp._cmd = FakeCmd(raises=True)
        cp._get_view_to_clipboard()   # must not raise
        self.assertIsNone(self._pasteboard_text())


class ConstantsTest(unittest.TestCase):
    def test_truncation_bounds(self):
        # The log keeps at most _MAX_LINES and trims down to _TRUNCATE_TO.
        self.assertGreater(cp._MAX_LINES, cp._TRUNCATE_TO)
        self.assertEqual(cp._MAX_LINES, 10000)
        self.assertEqual(cp._TRUNCATE_TO, 5000)


if __name__ == "__main__":
    unittest.main()
