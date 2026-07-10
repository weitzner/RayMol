"""Unit tests for pymol.appkit_theme_preview — headless, no PyMOL required.

Focuses on the scene-safety invariants of the theme-studio live preview:
begin() must never mutate the user's scene unless it holds a valid session
snapshot to restore from, must not overwrite an existing snapshot on a second
begin(), and restore() must put the captured session back and clear the
snapshot. `cmd` and `pymol.raymol_theme` are replaced with fakes after import.
"""

import io
import os
import sys
import types
import unittest
from contextlib import redirect_stdout

_MODULES_DIR = os.path.normpath(
    os.path.join(os.path.dirname(__file__), os.pardir, os.pardir, "modules")
)
if "pymol" not in sys.modules or not hasattr(sys.modules["pymol"], "__path__"):
    _pymol_stub = types.ModuleType("pymol")
    _pymol_stub.__path__ = [os.path.join(_MODULES_DIR, "pymol")]
    _pymol_stub.__package__ = "pymol"
    sys.modules["pymol"] = _pymol_stub
sys.modules["pymol"].cmd = types.SimpleNamespace()

# style() does `from pymol import raymol_theme as _rt`; give it a fake.
_rt = types.ModuleType("pymol.raymol_theme")
_rt._flat_sheets = True
_rt._fancy_helices = False
_rt.cbc = lambda sel: None
_rt.cnc = lambda sel: None
sys.modules["pymol.raymol_theme"] = _rt
sys.modules["pymol"].raymol_theme = _rt

from pymol import appkit_theme_preview as tp


class FakeCmd:
    def __init__(self, session=None, session_raises=False, atom_count=5):
        self.calls = []
        self._session = session if session is not None else {"S": 1}
        self._session_raises = session_raises
        self._atom_count = atom_count
        self.restored = None

    def get_session(self, partial=0, quiet=1):
        self.calls.append(("get_session",))
        if self._session_raises:
            raise RuntimeError("no session")
        return self._session

    def set_session(self, sess, partial=0, quiet=1):
        self.calls.append(("set_session",))
        self.restored = sess

    def count_atoms(self, sel):
        return self._atom_count

    def __getattr__(self, name):
        # Any other cmd.* (delete/load/disable/enable/orient/hide/show/set) is
        # recorded by name.
        def _rec(*a, **k):
            self.calls.append((name,) + a)
        return _rec

    def _names(self):
        return [c[0] for c in self.calls]


class BeginTest(unittest.TestCase):
    def setUp(self):
        tp._saved = None

    def test_begin_without_snapshot_leaves_scene_untouched(self):
        # get_session fails and there is no prior snapshot: begin() must bail
        # BEFORE disabling/deleting anything, or the user's scene is lost.
        cmd = FakeCmd(session_raises=True)
        tp.cmd = cmd
        with redirect_stdout(io.StringIO()):
            tp.begin("/tmp/example.pdb")
        names = cmd._names()
        self.assertNotIn("disable", names)
        self.assertNotIn("delete", names)
        self.assertNotIn("load", names)
        self.assertIsNone(tp._saved)

    def test_begin_snapshots_then_shows_example(self):
        cmd = FakeCmd(session={"real": "scene"}, atom_count=5)
        tp.cmd = cmd
        with redirect_stdout(io.StringIO()):
            tp.begin("/tmp/example.pdb")
        names = cmd._names()
        self.assertEqual(tp._saved, {"real": "scene"})
        # Loaded the example, hid everything else, showed + oriented the example.
        self.assertIn("load", names)
        self.assertIn("disable", names)   # disable("all")
        self.assertIn("enable", names)    # enable(OBJ)
        self.assertIn("orient", names)

    def test_begin_does_not_overwrite_existing_snapshot(self):
        # A second begin() (studio re-opened) must keep the ORIGINAL snapshot.
        tp._saved = {"original": True}
        cmd = FakeCmd(session={"newer": True})
        tp.cmd = cmd
        with redirect_stdout(io.StringIO()):
            tp.begin("/tmp/example.pdb")
        self.assertEqual(tp._saved, {"original": True})
        self.assertNotIn(("get_session",), cmd.calls)

    def test_begin_falls_back_to_fab_when_load_is_empty(self):
        cmd = FakeCmd(session={"real": 1}, atom_count=0)  # load yields 0 atoms
        tp.cmd = cmd
        with redirect_stdout(io.StringIO()):
            tp.begin("/tmp/example.pdb")
        self.assertIn("fab", cmd._names())


class RestoreTest(unittest.TestCase):
    def setUp(self):
        tp._saved = None

    def test_restore_puts_back_session_and_clears_saved(self):
        tp._saved = {"captured": 1}
        cmd = FakeCmd()
        tp.cmd = cmd
        with redirect_stdout(io.StringIO()):
            tp.restore()
        self.assertIn("delete", cmd._names())          # example removed
        self.assertEqual(cmd.restored, {"captured": 1})  # session restored
        self.assertIsNone(tp._saved)                    # snapshot cleared

    def test_restore_without_snapshot_only_deletes_example(self):
        tp._saved = None
        cmd = FakeCmd()
        tp.cmd = cmd
        with redirect_stdout(io.StringIO()):
            tp.restore()
        self.assertIn("delete", cmd._names())
        self.assertNotIn("set_session", cmd._names())


if __name__ == "__main__":
    unittest.main()
