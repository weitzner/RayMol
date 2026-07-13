"""Unit tests for pymol.appkit_menus — headless, no PyMOL/AppKit.

Covers the menu dispatch layer: _next_tag, the _menu_cmd/_menu_toggle/
_menu_radio/_menu_url registration into the tag->command/setting maps, the
_MenuTarget action handlers that turn a clicked item's tag into the right
cmd.do() string, and a full setup_menus() smoke build against fake menus.
AppKit/objc/Foundation are stubbed permissively before import.
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


class _NSObjectBase:
    """Bare stand-in for NSObject supporting alloc().init() and subclassing."""

    @classmethod
    def alloc(cls):
        return cls.__new__(cls)

    def init(self):
        return self


def _install_appkit_stubs():
    appkit = _PermissiveModule("AppKit")
    appkit.NSObject = _NSObjectBase
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

from pymol import appkit_menus as mn


class FakeMenuItem:
    def __init__(self, title, action, key):
        self.title, self.action, self.key = title, action, key
        self._tag = None
        self.target = None
        self.modmask = None

    def setTag_(self, t):
        self._tag = t

    def tag(self):
        return self._tag

    def setTarget_(self, t):
        self.target = t

    def setKeyEquivalentModifierMask_(self, m):
        self.modmask = m

    def setSubmenu_(self, sub):
        self.submenu = sub


class FakeMenu:
    def __init__(self, initial=0):
        self.items = [object() for _ in range(initial)]

    def addItemWithTitle_action_keyEquivalent_(self, title, action, key):
        it = FakeMenuItem(title, action, key)
        self.items.append(it)
        return it

    def addItem_(self, it):
        self.items.append(it)

    def setAutoenablesItems_(self, b):
        pass

    def setSubmenu_forItem_(self, sub, it):
        pass

    def numberOfItems(self):
        return len(self.items)

    def removeItemAtIndex_(self, i):
        del self.items[i]


class FakeCmd:
    def __init__(self):
        self.done = []

    def do(self, s):
        self.done.append(s)

    def get(self, name):
        return None


class FakeSender:
    def __init__(self, tag):
        self._tag = tag

    def tag(self):
        return self._tag


class MenuTestBase(unittest.TestCase):
    def setUp(self):
        mn._command_map.clear()
        mn._toggle_map.clear()
        mn._radio_map.clear()
        mn._retained.clear()
        mn._tag_counter = 0
        mn._target = None
        mn._cmd = FakeCmd()


class TagAndRegistrationTest(MenuTestBase):
    def test_next_tag_is_monotonic(self):
        a, b, c = mn._next_tag(), mn._next_tag(), mn._next_tag()
        self.assertTrue(a < b < c)

    def test_menu_cmd_registers_command(self):
        menu = FakeMenu()
        item = mn._menu_cmd(menu, "Zoom", "zoom", "z")
        self.assertEqual(item.action, "doCommand:")
        self.assertEqual(item.key, "z")
        self.assertEqual(mn._command_map[item.tag()], "zoom")
        self.assertIs(item.target, mn._get_target())

    def test_menu_toggle_registers_setting(self):
        menu = FakeMenu()
        item = mn._menu_toggle(menu, "Depth Cue", "depth_cue")
        self.assertEqual(item.action, "doToggle:")
        self.assertEqual(mn._toggle_map[item.tag()], "depth_cue")

    def test_menu_radio_registers_setting_value(self):
        menu = FakeMenu()
        item = mn._menu_radio(menu, "Lines", "ray_trace_mode", 0)
        self.assertEqual(item.action, "doRadio:")
        self.assertEqual(mn._radio_map[item.tag()], ("ray_trace_mode", 0))

    def test_menu_url_registers_url(self):
        menu = FakeMenu()
        item = mn._menu_url(menu, "Home", "http://pymol.org")
        self.assertEqual(item.action, "openURL:")
        self.assertEqual(mn._command_map[item.tag()], "http://pymol.org")


class MenuTargetDispatchTest(MenuTestBase):
    def test_do_command_executes_mapped_string(self):
        item = mn._menu_cmd(FakeMenu(), "Zoom", "zoom")
        mn._get_target().doCommand_(FakeSender(item.tag()))
        self.assertEqual(mn._cmd.done, ["zoom"])

    def test_do_toggle_emits_set_toggle(self):
        item = mn._menu_toggle(FakeMenu(), "Depth Cue", "depth_cue")
        mn._get_target().doToggle_(FakeSender(item.tag()))
        self.assertEqual(mn._cmd.done, ["set depth_cue, toggle"])

    def test_do_radio_emits_set_value(self):
        item = mn._menu_radio(FakeMenu(), "Mode 1", "ray_trace_mode", 1)
        mn._get_target().doRadio_(FakeSender(item.tag()))
        self.assertEqual(mn._cmd.done, ["set ray_trace_mode, 1"])

    def test_unknown_tag_does_nothing(self):
        mn._get_target().doCommand_(FakeSender(99999))
        self.assertEqual(mn._cmd.done, [])

    def test_open_url_opens_browser(self):
        item = mn._menu_url(FakeMenu(), "Home", "http://pymol.org")
        fake_wb = MagicMock()
        orig = mn.webbrowser
        mn.webbrowser = fake_wb
        try:
            mn._get_target().openURL_(FakeSender(item.tag()))
        finally:
            mn.webbrowser = orig
        fake_wb.open.assert_called_once_with("http://pymol.org")


class SetupMenusSmokeTest(MenuTestBase):
    def test_setup_menus_builds_full_bar_and_registers_commands(self):
        menubar = FakeMenu(initial=1)   # the app menu at index 0
        # Patch the AppKit reference appkit_menus actually holds (import order can
        # leave sys.modules["AppKit"] pointing at a different stub).
        mn.AppKit.NSApp = MagicMock()
        mn.AppKit.NSApp.mainMenu.return_value = menubar

        mn.setup_menus(FakeCmd())

        # 10 top-level menus were appended after the app menu.
        self.assertEqual(menubar.numberOfItems(), 11)
        # The build wired up a substantial number of command/toggle/radio items.
        self.assertGreater(len(mn._command_map), 40)
        self.assertGreater(len(mn._toggle_map), 0)
        self.assertGreater(len(mn._radio_map), 0)


if __name__ == "__main__":
    unittest.main()
