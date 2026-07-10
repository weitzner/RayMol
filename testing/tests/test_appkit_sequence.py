"""Unit tests for pymol.appkit_sequence — headless, no PyMOL required.

Covers the sequence-panel data builder: per-object guide-residue rows
(_object_rows), the theme-preview rename, and the BIMO-style gap-alignment
merge (_apply_alignments) that re-lays-out members of an enabled alignment so
aligned residues share a column. `cmd` is replaced with a fake that executes
iterate() expressions against in-memory atom dicts.
"""

import os
import sys
import types
import unittest

_MODULES_DIR = os.path.normpath(
    os.path.join(os.path.dirname(__file__), os.pardir, os.pardir, "modules")
)
if "pymol" not in sys.modules or not hasattr(sys.modules["pymol"], "__path__"):
    _pymol_stub = types.ModuleType("pymol")
    _pymol_stub.__path__ = [os.path.join(_MODULES_DIR, "pymol")]
    _pymol_stub.__package__ = "pymol"
    sys.modules["pymol"] = _pymol_stub
sys.modules["pymol"].cmd = types.SimpleNamespace()

from pymol import appkit_sequence as seq


class FakeCmd:
    """In-memory object model that can execute the two iterate() expressions
    appkit_sequence uses:
      - `r.append([chain, resi, resn, str(color)])`  over `(obj) and guide`
      - `mm[index] = (chain, resi)`                   over `obj`
    """

    def __init__(self, objects, enabled=None, raw=None):
        # objects: {name: {"type": str, "atoms": [ {chain,resi,resn,color,index}, ... ]}}
        self._objects = objects
        self._enabled = set(enabled or objects.keys())
        self._raw = raw or {}

    def get_type(self, name):
        return self._objects[name]["type"]

    def get_names(self, kind="objects", enabled_only=0):
        names = list(self._objects.keys())
        if enabled_only:
            names = [n for n in names if n in self._enabled]
        return names

    def get_raw_alignment(self, aln):
        return self._raw.get(aln)

    def get_color_tuple(self, ci):
        return (0.1 * ci, 0.2, 0.3)

    def iterate(self, selection, expression, space=None):
        space = space if space is not None else {}
        base, guide_only = selection.strip(), False
        if base.endswith(" and guide"):
            base = base[: -len(" and guide")].strip()
            guide_only = True
        base = base.strip("()")
        atoms = self._objects.get(base, {}).get("atoms", [])
        for atom in atoms:
            if guide_only and not atom.get("guide", True):
                continue
            ns = dict(space)
            ns.update(atom)
            exec(expression, {}, ns)


def _mol(name_atoms):
    return {"type": "object:molecule", "atoms": name_atoms}


def _atom(chain, resi, resn, color, index, guide=True):
    return {"chain": chain, "resi": resi, "resn": resn,
            "color": color, "index": index, "guide": guide}


class ObjectRowsTest(unittest.TestCase):
    def test_basic_rows_cols_posmap(self):
        cmd = FakeCmd({
            "molA": _mol([_atom("A", "1", "ALA", 5, 101),
                          _atom("A", "2", "GLY", 6, 102)]),
        })
        seq.cmd = cmd
        out, cols, posmap = seq._object_rows(["molA"])
        self.assertEqual(len(out), 1)
        self.assertEqual(out[0]["name"], "molA")
        self.assertEqual(out[0]["residues"],
                         [["A", "1", "ALA", "5"], ["A", "2", "GLY", "6"]])
        self.assertEqual(set(cols.keys()), {"5", "6"})
        self.assertEqual(posmap["molA"], {("A", "1"): 0, ("A", "2"): 1})

    def test_non_molecule_and_empty_skipped(self):
        cmd = FakeCmd({
            "molA": _mol([_atom("A", "1", "ALA", 5, 101)]),
            "aln": {"type": "object:alignment", "atoms": []},
            "empty": _mol([]),
        })
        seq.cmd = cmd
        out, cols, posmap = seq._object_rows(["molA", "aln", "empty"])
        self.assertEqual([d["name"] for d in out], ["molA"])

    def test_theme_preview_renamed_but_posmap_keyed_by_real_name(self):
        cmd = FakeCmd({
            "__theme_preview": _mol([_atom("A", "1", "ALA", 5, 101)]),
        })
        seq.cmd = cmd
        out, cols, posmap = seq._object_rows(["__theme_preview"])
        self.assertEqual(out[0]["name"], "example")      # display remap
        self.assertIn("__theme_preview", posmap)          # posmap real name


class ApplyAlignmentsTest(unittest.TestCase):
    def _two_aligned_mols(self, enabled):
        # molA resi 1,2,3 (idx 101-103); molB resi 1,2,3 (idx 201-203).
        objects = {
            "molA": _mol([_atom("A", "1", "ALA", 5, 101),
                          _atom("A", "2", "GLY", 6, 102),
                          _atom("A", "3", "SER", 7, 103)]),
            "molB": _mol([_atom("B", "1", "ALA", 5, 201),
                          _atom("B", "2", "GLY", 6, 202),
                          _atom("B", "3", "SER", 7, 203)]),
            "aln": {"type": "object:alignment", "atoms": []},
        }
        # Align resi2<->resi2 and resi3<->resi3 (resi1 unaligned on both).
        raw = {"aln": [
            [("molA", 102), ("molB", 202)],
            [("molA", 103), ("molB", 203)],
        ]}
        return FakeCmd(objects, enabled=enabled, raw=raw)

    def test_enabled_alignment_inserts_gaps_and_shares_columns(self):
        cmd = self._two_aligned_mols(enabled={"molA", "molB", "aln"})
        seq.cmd = cmd
        out, cols, posmap = seq._object_rows(["molA", "molB"])
        seq._apply_alignments(out, posmap)
        rows = {d["name"]: d["residues"] for d in out}
        # Both members padded to equal length.
        self.assertEqual(len(rows["molA"]), len(rows["molB"]))
        # The unaligned leading residues are offset by a gap on the other row.
        self.assertEqual(rows["molA"][0], ["A", "1", "ALA", "5"])
        self.assertEqual(rows["molB"][0], seq._GAP)
        self.assertEqual(rows["molA"][1], seq._GAP)
        self.assertEqual(rows["molB"][1], ["B", "1", "ALA", "5"])
        # Aligned residues (resi2, resi3) occupy the SAME column on both rows.
        for col in range(len(rows["molA"])):
            a, b = rows["molA"][col], rows["molB"][col]
            if a != seq._GAP and b != seq._GAP:
                self.assertEqual(a[1], b[1])  # same resi in a shared column

    def test_disabled_alignment_is_noop(self):
        cmd = self._two_aligned_mols(enabled={"molA", "molB"})  # aln NOT enabled
        seq.cmd = cmd
        out, cols, posmap = seq._object_rows(["molA", "molB"])
        before = {d["name"]: list(d["residues"]) for d in out}
        seq._apply_alignments(out, posmap)
        after = {d["name"]: d["residues"] for d in out}
        self.assertEqual(before, after)   # no gaps inserted

    def test_build_preview_skips_alignment(self):
        cmd = self._two_aligned_mols(enabled={"molA", "molB", "aln"})
        seq.cmd = cmd
        data = seq._build(["molA", "molB"], preview=True)
        # preview=True must NOT gap-align even with the alignment enabled.
        rows = {d["name"]: d["residues"] for d in data["objects"]}
        self.assertNotIn(seq._GAP, rows["molA"])
        self.assertNotIn(seq._GAP, rows["molB"])

    def test_build_fills_color_tuples(self):
        cmd = FakeCmd({"molA": _mol([_atom("A", "1", "ALA", 5, 101)])},
                      enabled={"molA"})
        seq.cmd = cmd
        data = seq._build(["molA"], preview=False)
        self.assertEqual(data["colors"]["5"], (0.5, 0.2, 0.3))


class GapConstantTest(unittest.TestCase):
    def test_gap_shape(self):
        # Empty chain/resi, resn '-', color '-1' (no color entry).
        self.assertEqual(seq._GAP, ["", "", "-", "-1"])


if __name__ == "__main__":
    unittest.main()
