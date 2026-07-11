"""Unit tests for pymol.appkit_sequence_panel — headless, no PyMOL/AppKit.

Covers the sequence-extraction logic (_get_sequences): enabled-molecule
filtering, residue dedup, 3->1 letter mapping (_AA3TO1) with '?' fallback, the
get_fastastr fallback path, and the click-to-select target that builds the
`obj and chain X and resi N` selection. AppKit/objc/Foundation stubbed.
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

from pymol import appkit_sequence_panel as sp


def _atom(chain, resn, resi):
    return types.SimpleNamespace(chain=chain, resn=resn, resi=resi)


class FakeModel:
    def __init__(self, atoms):
        self.atom = atoms


class FakeCmd:
    def __init__(self, objects, types_=None, models=None, fasta=None):
        self._objects = objects        # enabled public objects
        self._types = types_ or {}
        self._models = models or {}
        self._fasta = fasta or {}

    def get_names(self, kind="public_objects", enabled_only=0):
        return list(self._objects)

    def get_type(self, name):
        return self._types.get(name, "object:molecule")

    def get_model(self, selection):
        base = selection.split(" and ")[0]
        if base not in self._models:
            raise RuntimeError("no model")
        return self._models[base]

    def get_fastastr(self, name):
        return self._fasta.get(name)


class Aa3To1Test(unittest.TestCase):
    def test_core_mappings(self):
        self.assertEqual(sp._AA3TO1["ALA"], "A")
        self.assertEqual(sp._AA3TO1["TRP"], "W")
        self.assertEqual(sp._AA3TO1["MSE"], "M")   # modified residue
        self.assertEqual(sp._AA3TO1["DA"], "A")    # nucleic acid

    def test_unknown_maps_via_get_default(self):
        self.assertEqual(sp._AA3TO1.get("XYZ", "?"), "?")


class GetSequencesTest(unittest.TestCase):
    def tearDown(self):
        sp._cmd = None

    def test_returns_empty_without_cmd(self):
        sp._cmd = None
        self.assertEqual(sp._get_sequences(), [])

    def test_dedups_and_maps_residues(self):
        atoms = [
            _atom("A", "ALA", "1"),
            _atom("A", "ALA", "1"),   # duplicate guide atom -> collapsed
            _atom("A", "GLY", "2"),
            _atom("A", "XYZ", "3"),   # unknown -> '?'
        ]
        sp._cmd = FakeCmd(["molA"], models={"molA": FakeModel(atoms)})
        seqs = sp._get_sequences()
        self.assertEqual(len(seqs), 1)
        name, residues = seqs[0]
        self.assertEqual(name, "molA")
        self.assertEqual([r[1] for r in residues], ["A", "G", "?"])
        self.assertEqual([r[0] for r in residues], ["A", "A", "A"])  # chain

    def test_skips_non_molecule_objects(self):
        sp._cmd = FakeCmd(
            ["aln"], types_={"aln": "object:alignment"},
            models={"aln": FakeModel([_atom("A", "ALA", "1")])})
        self.assertEqual(sp._get_sequences(), [])

    def test_falls_back_to_fastastr(self):
        # get_model raises for this object -> use get_fastastr.
        sp._cmd = FakeCmd(["molB"], models={}, fasta={"molB": ">molB\nACD\n"})
        seqs = sp._get_sequences()
        self.assertEqual(len(seqs), 1)
        self.assertEqual([r[1] for r in seqs[0][1]], ["A", "C", "D"])


class ClickTargetTest(unittest.TestCase):
    def _target(self, cmd, obj, resi, chain):
        t = sp.SeqPanel_ClickTarget.__new__(sp.SeqPanel_ClickTarget)
        t._cmd = cmd
        t._obj_name = obj
        t._resi = resi
        t._chain = chain
        return t

    def test_builds_chain_and_resi_selection(self):
        cmd = MagicMock()
        self._target(cmd, "molA", "5", "A").clicked_(None)
        cmd.select.assert_called_once_with("sele", "molA and chain A and resi 5")
        cmd.center.assert_called_once_with("molA and chain A and resi 5", animate=-1)

    def test_object_only_selection_when_no_chain_resi(self):
        cmd = MagicMock()
        self._target(cmd, "molA", "", "").clicked_(None)
        cmd.select.assert_called_once_with("sele", "molA")


class ConstantsTest(unittest.TestCase):
    def test_seq_bar_height(self):
        self.assertEqual(sp.SEQ_BAR_HEIGHT, 22)

    def test_chain_color_cycle_has_six(self):
        self.assertEqual(len(sp._CHAIN_COLORS), 6)


if __name__ == "__main__":
    unittest.main()
