'''
Multi-state objects in the movie timeline (appkit_movie.rebuild).

Verifies the non-destructive default, per-object state sweeps, and independence
of multiple multi-state objects. Per-object ViewElem state is applied at RENDER
(ObjectPrepareContext), so state assertions ray a tiny image per sampled frame
to force the apply, then read the object's own `state` setting.
'''

from pymol import cmd, testing, appkit_movie
import json


class TestMultistateTimeline(testing.PyMOLTestCase):

    def _ensemble(self, name, n):
        # Build an n-state object by copying a monomer's state 1 into states 1..n.
        cmd.fab('AG', 'mono')
        cmd.disable('mono')
        for i in range(1, n + 1):
            cmd.create(name, 'mono', 1, i)
        self.assertEqual(cmd.count_states(name), n)

    def _ostate(self, obj, frame):
        cmd.frame(frame)
        cmd.ray(20, 20)                     # force ObjectPrepareContext (state apply)
        return int(cmd.get('state', obj))

    def test_multistate_objects_detects_counts(self):
        cmd.reinitialize()
        self._ensemble('nmr', 10)
        cmd.fab('A', 'solo')                # single state
        d = appkit_movie._multistate_objects()
        self.assertEqual(d.get('nmr'), 10)
        self.assertNotIn('solo', d)

    def test_empty_authors_no_mset(self):
        cmd.reinitialize()
        self._ensemble('nmr', 10)
        appkit_movie.rebuild('[]')
        # No mset => count_frames falls back to the state count.
        self.assertEqual(cmd.count_frames(), 10)

    def test_camera_only_does_not_freeze_ensemble(self):
        cmd.reinitialize()
        self._ensemble('nmr', 10)
        spec = [{'frame': 1, 'cam': 'A', 'power': 0.0, 'linear': 0},
                {'frame': 60, 'cam': 'B', 'power': 0.0, 'linear': 0}]
        appkit_movie.rebuild(json.dumps(spec))
        seen = {self._ostate('nmr', f) for f in range(1, cmd.count_frames() + 1, 6)}
        seen.add(self._ostate('nmr', cmd.count_frames()))
        self.assertGreaterEqual(max(seen), 9)   # auto-sweeps, not frozen on state 1
        self.assertGreaterEqual(len(seen), 5)

    def test_two_ensembles_sweep_independently(self):
        cmd.reinitialize()
        self._ensemble('short', 5)
        self._ensemble('long', 40)
        spec = [{'frame': 1, 'end': 80, 'states': 1, 'objects': None, 'mode': 'sweep'}]
        appkit_movie.rebuild(json.dumps(spec))
        ss, ls = set(), set()
        for f in list(range(1, cmd.count_frames() + 1, 8)) + [cmd.count_frames()]:
            cmd.frame(f); cmd.ray(20, 20)
            ss.add(int(cmd.get('state', 'short')))
            ls.add(int(cmd.get('state', 'long')))
        self.assertLessEqual(max(ss), 5)         # short not clamped to long's range
        self.assertEqual(max(ls), 40)            # long reaches its own max
        self.assertGreaterEqual(max(ss), 5)      # and short reaches its own max

    def test_states_clip_model_range(self):
        cmd.reinitialize()
        self._ensemble('nmr', 10)
        spec = [{'frame': 1, 'end': 80, 'states': 1, 'objects': None,
                 'mode': 'sweep', 'first': 3, 'last': 7}]
        appkit_movie.rebuild(json.dumps(spec))
        seen = set()
        for f in list(range(1, cmd.count_frames() + 1, 6)) + [cmd.count_frames()]:
            cmd.frame(f); cmd.ray(20, 20)
            seen.add(int(cmd.get('state', 'nmr')))
        self.assertGreaterEqual(min(seen), 3)     # never below the requested first
        self.assertLessEqual(max(seen), 7)        # never above the requested last
        self.assertEqual(max(seen), 7)

    def test_reset_ensemble_restores_all_models(self):
        cmd.reinitialize()
        self._ensemble('nmr', 10)
        appkit_movie.rebuild(json.dumps([{'frame': 1, 'cam': 'A', 'power': 0.0, 'linear': 0}]))
        appkit_movie.reset_ensemble()
        self.assertEqual(cmd.count_frames(), 10)
