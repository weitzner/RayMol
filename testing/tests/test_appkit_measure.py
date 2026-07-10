"""Unit tests for pymol.appkit_measure — headless, no PyMOL/GPU required.

Exercises the pick-driven distance/angle/dihedral state machine: mode
selection, pick accumulation, commit-on-enough-picks, rounding, the
MEASURE:<json> feedback contract, reset, and clear_all. `cmd` and
`metal_pick` are replaced with recording fakes after import.
"""

import io
import json
import os
import sys
import types
import unittest
from contextlib import redirect_stdout

# --- Bootstrap a pymol package stub pointing at the real modules/pymol -------
_MODULES_DIR = os.path.normpath(
    os.path.join(os.path.dirname(__file__), os.pardir, os.pardir, "modules")
)
if "pymol" not in sys.modules or not hasattr(sys.modules["pymol"], "__path__"):
    _pymol_stub = types.ModuleType("pymol")
    _pymol_stub.__path__ = [os.path.join(_MODULES_DIR, "pymol")]
    _pymol_stub.__package__ = "pymol"
    sys.modules["pymol"] = _pymol_stub
# Give `from pymol import cmd` / `metal_pick` placeholders so import is cheap and
# does not drag in the _cmd C-extension or numpy. Real fakes are injected below.
# Only when absent: inside a real `pymol -ckqy` run these already exist and must
# NOT be clobbered (that would break every other test in the shared process).
if not hasattr(sys.modules["pymol"], "cmd"):
    sys.modules["pymol"].cmd = types.SimpleNamespace()
if not hasattr(sys.modules["pymol"], "metal_pick"):
    sys.modules["pymol"].metal_pick = types.SimpleNamespace()

from pymol import appkit_measure as m


class FakeCmd:
    """Records the measurement calls and returns canned values."""

    def __init__(self, dist=None, ang=None, dih=None, objects=None, types_=None):
        self.calls = []
        self._dist, self._ang, self._dih = dist, ang, dih
        self._objects = objects or []
        self._types = types_ or {}
        self.selections = []

    # -- selection bookkeeping used for highlighting --
    def get_names(self, kind):
        return self.selections if kind == "selections" else list(self._objects)

    def select(self, name, expr):
        self.calls.append(("select", name, expr))
        if name not in self.selections:
            self.selections.append(name)

    def enable(self, name):
        self.calls.append(("enable", name))

    # -- measurement creators --
    def distance(self, name, a, b):
        self.calls.append(("distance", name, a, b))
        return self._dist

    def angle(self, name, a, b, c):
        self.calls.append(("angle", name, a, b, c))
        return self._ang

    def dihedral(self, name, a, b, c, d):
        self.calls.append(("dihedral", name, a, b, c, d))
        return self._dih

    # -- clear_all support --
    def get_type(self, name):
        return self._types.get(name, "object:molecule")

    def delete(self, name):
        self.calls.append(("delete", name))


class FakeMetalPick:
    """Returns a preset queue of picks; atom_expr echoes the token."""

    def __init__(self, tokens):
        self._tokens = list(tokens)
        self._i = 0

    def _pick_atom(self, x, y, aspect):
        if self._i >= len(self._tokens):
            return None
        tok = self._tokens[self._i]
        self._i += 1
        return tok

    def atom_expr(self, tok):
        return None if tok is None else "expr(%s)" % tok


def _emitted(fake_out):
    """Return the list of parsed MEASURE: json dicts printed to stdout."""
    out = []
    for line in fake_out.getvalue().splitlines():
        if line.startswith("MEASURE:"):
            out.append(json.loads(line[len("MEASURE:"):]))
    return out


class AppkitMeasureTest(unittest.TestCase):
    def setUp(self):
        # Reset module state between tests.
        m._kind = "distance"
        m._picks = []
        m._counter = 0

    def _install(self, tokens=(), **cmdkw):
        m.metal_pick = FakeMetalPick(tokens)
        m.cmd = FakeCmd(**cmdkw)
        return m.cmd

    # -- set_mode / _NEED ----------------------------------------------------
    def test_need_table(self):
        self.assertEqual(m._NEED, {"distance": 2, "angle": 3, "dihedral": 4})

    def test_set_mode_valid(self):
        self._install()
        with redirect_stdout(io.StringIO()):
            m.set_mode("angle")
        self.assertEqual(m._kind, "angle")

    def test_set_mode_invalid_falls_back_to_distance(self):
        self._install()
        with redirect_stdout(io.StringIO()):
            m.set_mode("bogus")
        self.assertEqual(m._kind, "distance")

    def test_set_mode_resets_picks(self):
        self._install()
        m._picks = ["expr(1)"]
        with redirect_stdout(io.StringIO()):
            m.set_mode("dihedral")
        self.assertEqual(m._picks, [])

    # -- pick accumulation + commit -----------------------------------------
    def test_distance_commits_on_second_pick(self):
        cmd = self._install(tokens=[10, 20], dist=3.14159)
        m._kind = "distance"
        buf = io.StringIO()
        with redirect_stdout(buf):
            m.pick(0.0, 0.0, 1.0)   # first pick: accumulate
            self.assertEqual(len(m._picks), 1)
            m.pick(0.1, 0.1, 1.0)   # second pick: commit
        # A distance object was created from the two atom exprs.
        dist_calls = [c for c in cmd.calls if c[0] == "distance"]
        self.assertEqual(len(dist_calls), 1)
        self.assertEqual(dist_calls[0][2:], ("expr(10)", "expr(20)"))
        # Picks reset after commit.
        self.assertEqual(m._picks, [])
        # Feedback: count 1 (need 2, no value), then the committed value.
        emitted = _emitted(buf)
        self.assertEqual(emitted[0], {"kind": "distance", "count": 1, "need": 2})
        self.assertEqual(emitted[-1]["value"], 3.14)   # rounded to 2 dp

    def test_angle_needs_three_picks(self):
        cmd = self._install(tokens=[1, 2, 3], ang=90.66)
        m._kind = "angle"
        buf = io.StringIO()
        with redirect_stdout(buf):
            m.pick(0, 0, 1.0)
            m.pick(0, 0, 1.0)
            self.assertEqual(len(m._picks), 2)   # not committed yet
            m.pick(0, 0, 1.0)
        self.assertTrue(any(c[0] == "angle" for c in cmd.calls))
        self.assertEqual(_emitted(buf)[-1]["value"], 90.7)   # 1 dp

    def test_dihedral_rounds_to_one_dp(self):
        cmd = self._install(tokens=[1, 2, 3, 4], dih=-59.98)
        m._kind = "dihedral"
        buf = io.StringIO()
        with redirect_stdout(buf):
            for _ in range(4):
                m.pick(0, 0, 1.0)
        self.assertTrue(any(c[0] == "dihedral" for c in cmd.calls))
        self.assertEqual(_emitted(buf)[-1]["value"], -60.0)

    def test_pick_miss_is_ignored(self):
        self._install(tokens=[None])   # _pick_atom returns None
        m._kind = "distance"
        with redirect_stdout(io.StringIO()):
            m.pick(0, 0, 1.0)
        self.assertEqual(m._picks, [])

    def test_commit_with_none_value_omits_value_key(self):
        # A degenerate measurement (cmd.distance returns None) still commits and
        # clears the picks, but _emit(None) omits the 'value' key — so the final
        # feedback is count 0, indistinguishable from a reset.
        cmd = self._install(tokens=[1, 2], dist=None)
        m._kind = "distance"
        buf = io.StringIO()
        with redirect_stdout(buf):
            m.pick(0, 0, 1.0)
            m.pick(0, 0, 1.0)
        self.assertTrue(any(c[0] == "distance" for c in cmd.calls))  # committed
        self.assertEqual(m._picks, [])
        self.assertNotIn("value", _emitted(buf)[-1])

    # -- reset / clear_all ---------------------------------------------------
    def test_reset_clears_and_emits_zero(self):
        self._install(tokens=[1])
        m._kind = "distance"
        with redirect_stdout(io.StringIO()):
            m.pick(0, 0, 1.0)
        buf = io.StringIO()
        with redirect_stdout(buf):
            m.reset()
        self.assertEqual(m._picks, [])
        self.assertEqual(_emitted(buf)[-1], {"kind": "distance", "count": 0, "need": 2})

    def test_clear_all_deletes_only_measurement_objects(self):
        cmd = self._install(
            objects=["mol1", "dist01", "ang01"],
            types_={
                "mol1": "object:molecule",
                "dist01": "object:measurement",
                "ang01": "object:measurement",
            },
        )
        with redirect_stdout(io.StringIO()):
            m.clear_all()
        deleted = {c[1] for c in cmd.calls if c[0] == "delete"}
        self.assertEqual(deleted, {"dist01", "ang01"})


if __name__ == "__main__":
    unittest.main()
