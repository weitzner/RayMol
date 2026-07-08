"""Tests for pymol.appkit_inspector per-atom transparency discoverability.

Covers the detection that drives the inspector's per-atom transparency badge and
"per-atom: min-max" + Clear detail row (issue #122): transp_summary,
object_has_atom_transp, and the atom_transp field attached by _build.
"""

from pymol import cmd, testing
from pymol import appkit_inspector as ai


class TestInspectorTransparency(testing.PyMOLTestCase):

    def _peptide(self, name='pep'):
        cmd.delete(name)
        cmd.fab('ACDEFGHIKLMNPQRSTVWY', name)
        cmd.dss(name)
        cmd.show_as('cartoon', name)
        return name

    def testCleanObjectHasNoOverride(self):
        o = self._peptide()
        summ = ai.transp_summary(o)
        self.assertFalse(summ['cartoon_transparency'][2])
        self.assertFalse(ai.object_has_atom_transp(o))
        cart = [r for r in ai._build([o])['detail'][o] if r['rep'] == 'cartoon'][0]
        self.assertNotIn('atom_transp', cart)

    def testPartialOverrideDetected(self):
        o = self._peptide()
        cmd.alter(o + ' and resi 1-10', 's.cartoon_transparency = 0.5')
        # effective range spans object-level (0) .. override (0.5), flagged as over
        self.assertEqual(ai.transp_summary(o)['cartoon_transparency'], (0.0, 0.5, True))
        self.assertTrue(ai.object_has_atom_transp(o))
        cart = [r for r in ai._build([o])['detail'][o] if r['rep'] == 'cartoon'][0]
        self.assertEqual(cart['atom_transp'],
                         {'setting': 'cartoon_transparency', 'min': 0.0, 'max': 0.5})

    def testUniformOverrideDiffersFromSlider(self):
        # every atom overridden to 0.5 while the object-level slider is still 0 ->
        # still an override (the slider misrepresents what's rendered)
        o = self._peptide()
        cmd.alter(o, 's.cartoon_transparency = 0.5')
        self.assertEqual(ai.transp_summary(o)['cartoon_transparency'], (0.5, 0.5, True))

    def testOverrideEqualToSliderIsNotFlagged(self):
        # per-atom value equal to the object-level value must NOT flag (no false alarm)
        o = self._peptide()
        cmd.alter(o, 's.cartoon_transparency = 0.5')
        cmd.set('cartoon_transparency', 0.5, o)
        self.assertFalse(ai.transp_summary(o)['cartoon_transparency'][2])
        self.assertFalse(ai.object_has_atom_transp(o))

    def testClearRestoresSliderAuthority(self):
        # the Clear action runs `unset <setting>, (<obj>)`; verify it removes the
        # per-atom overrides, keeps the object-level value, and lets the slider govern
        o = self._peptide()
        cmd.set('cartoon_transparency', 0.3, o)
        cmd.alter(o + ' and resi 1-10', 's.cartoon_transparency = 0.7')
        self.assertTrue(ai.transp_summary(o)['cartoon_transparency'][2])
        cmd.unset('cartoon_transparency', '(%s)' % o)
        c = ai.transp_summary(o)['cartoon_transparency']
        self.assertEqual(c[:2], (0.3, 0.3))
        self.assertFalse(c[2])
        cmd.set('cartoon_transparency', 0.8, o)
        self.assertEqual(ai.transp_summary(o)['cartoon_transparency'][:2], (0.8, 0.8))

    def testFlagIsGatedByActiveRep(self):
        # an override on a rep that isn't shown must not raise the badge
        o = self._peptide()
        cmd.alter(o + ' and resi 1-5', 's.sphere_transparency = 0.4')
        self.assertFalse(ai.object_has_atom_transp(o))  # spheres hidden
        cmd.show('spheres', o)
        self.assertTrue(ai.object_has_atom_transp(o))    # spheres shown

    def testNonAtomLevelSettingsExcluded(self):
        # ribbon_/stick_transparency are object-level only and must not appear in
        # the atom-level detection set (they can never carry per-atom overrides)
        self.assertNotIn('ribbon_transparency', ai.TRANSP_SETTINGS)
        self.assertNotIn('stick_transparency', ai.TRANSP_SETTINGS)
        self.assertIn('cartoon_transparency', ai.TRANSP_SETTINGS)
        self.assertIn('sphere_transparency', ai.TRANSP_SETTINGS)
        self.assertIn('transparency', ai.TRANSP_SETTINGS)
