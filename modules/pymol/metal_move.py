"""Rigid-body object Move mode for the Metal backend (gizmo manipulation).

Vanilla PyMOL moves objects via three_button_editing, whose drag relies on
SceneClick/SceneDoXYPick (GL color picking) — dead on the Metal backend. This
module reproduces the *object-level* move (translate / rotate of a whole object)
driven from Swift gestures instead:

  * All 3D->2D projection reuses the verified camera math from metal_pick
    (cmd.get_view; both the 18-float embedded layout and the 25-float layout are
    handled defensively).
  * All manipulation is non-destructive: cmd.translate / cmd.rotate with
    object=<name> modify the object's TTT display matrix (atom coordinates are
    never touched; the move is saved in the .pse and reset via matrix_reset).
  * The gizmo geometry (projected handle positions for the active tool) is
    written to <tmpdir>/pymol_gizmo.json after every call. Swift reads it back
    synchronously (the longPressPick pattern) to draw the overlay and hit-test
    handles in 2D.

NDC convention matches metal_pick / the MetalViewport gesture handlers:
bottom-left origin, +x right, +y up, in [-1, 1].
"""
import json
import math
import os
import tempfile

from pymol import cmd

# Module state ---------------------------------------------------------------
_active = None          # active object name, or None
_tool = 'translate'     # 'translate' | 'rotate'
_aspect = 1.0           # last viewport aspect (width / height)
_drag = None            # in-flight drag: {handle, px, py, dx, dy, dz, deg}
# Move mode manipulates the object's TTT display matrix (cmd.translate/rotate with
# object=). This is non-destructive: atom coordinates are untouched, the move is
# saved in the .pse, and reset_active() clears it via matrix_reset. (The Metal
# renderer applies the object TTT — see the ObjectPrepareContext / Scene modelview
# sync in the C++ layer.)

# Gizmo sizing, in NDC (constant on-screen size regardless of zoom).
_AXIS_NDC = 0.18        # arrow half-length
_PLANE_NDC = 0.08       # plane-handle offset from center
_RING_NDC = 0.16        # rotation-ring radius
_RING_SEG = 48          # ring polyline samples

_AXES = {'x': (1.0, 0.0, 0.0), 'y': (0.0, 1.0, 0.0), 'z': (0.0, 0.0, 1.0)}
# Orthonormal basis (u, v) spanning the plane perpendicular to each world axis,
# used to sample that axis's rotation ring.
_RING_BASIS = {
    'x': ((0.0, 1.0, 0.0), (0.0, 0.0, 1.0)),
    'y': ((1.0, 0.0, 0.0), (0.0, 0.0, 1.0)),
    'z': ((1.0, 0.0, 0.0), (0.0, 1.0, 0.0)),
}
_PATH = os.path.join(tempfile.gettempdir(), 'pymol_gizmo.json')


# --- View / projection (mirrors metal_pick) ---------------------------------

def _view_params(aspect):
    """(r0, r1, r2, t, o, tan_half, aspect) from cmd.get_view(), or None."""
    try:
        v = cmd.get_view()
    except Exception:
        return None
    if not v:
        return None
    if len(v) >= 25:
        r0 = (v[0], v[4], v[8]); r1 = (v[1], v[5], v[9]); r2 = (v[2], v[6], v[10])
        t = (v[16], v[17], v[18]); o = (v[19], v[20], v[21]); fov = abs(v[24])
    else:  # 18-float embedded layout (what this build returns)
        r0 = (v[0], v[3], v[6]); r1 = (v[1], v[4], v[7]); r2 = (v[2], v[5], v[8])
        t = (v[9], v[10], v[11]); o = (v[12], v[13], v[14]); fov = abs(v[17])
    if fov <= 1.0:
        try:
            fov = cmd.get_setting_float('field_of_view')
        except Exception:
            fov = 20.0
    fov_width = 2.0 * math.tan(math.radians(fov) / 2.0)
    tan_half = math.tan(fov_width / 2.0)
    if tan_half <= 0.0 or aspect <= 0.0:
        return None
    return (r0, r1, r2, t, o, tan_half, aspect)


def _project(params, p):
    """Model-space point -> (ndc_x, ndc_y, depth), or None if behind camera."""
    r0, r1, r2, t, o, tan_half, aspect = params
    dx = p[0] - o[0]; dy = p[1] - o[1]; dz = p[2] - o[2]
    ex = r0[0] * dx + r0[1] * dy + r0[2] * dz + t[0]
    ey = r1[0] * dx + r1[1] * dy + r1[2] * dz + t[1]
    ez = r2[0] * dx + r2[1] * dy + r2[2] * dz + t[2]
    depth = -ez
    if depth <= 0.01:
        return None
    half_h = depth * tan_half
    half_w = half_h * aspect
    return (ex / half_w, ey / half_h, depth)


# --- Active object center (displayed, incl. TTT) ----------------------------

def _object_exists(obj):
    if not obj:
        return False
    try:
        return obj in (cmd.get_names('objects') or [])
    except Exception:
        return False


def _center():
    """Displayed center of the active object: the untransformed coordinate
    centroid (iterate_state, guaranteed pre-TTT) transformed by the object's
    matrix (incl. TTT) so the gizmo tracks a moved object. None if unavailable."""
    obj = _active
    if not _object_exists(obj):
        return None
    acc = [0.0, 0.0, 0.0, 0]
    try:
        cmd.iterate_state(1, '(%s)' % obj,
                          'acc[0] += x; acc[1] += y; acc[2] += z; acc[3] += 1',
                          space={'acc': acc})
    except Exception:
        return None
    if acc[3] == 0:
        return None
    c = [acc[0] / acc[3], acc[1] / acc[3], acc[2] / acc[3]]
    try:
        m = cmd.get_object_matrix(obj)   # 16 floats, row-major, incl. TTT
        if m and len(m) >= 16:
            c = [m[0] * c[0] + m[1] * c[1] + m[2] * c[2] + m[3],
                 m[4] * c[0] + m[5] * c[1] + m[6] * c[2] + m[7],
                 m[8] * c[0] + m[9] * c[1] + m[10] * c[2] + m[11]]
    except Exception:
        pass
    return c


def _axis_screen_dir(params, center, axis):
    """Screen displacement (ndc) of a 1 Angstrom step along `axis` at `center`,
    i.e. (proj(center+axis) - proj(center)) projected to NDC. None if behind."""
    c = _project(params, center)
    a = _project(params, (center[0] + axis[0], center[1] + axis[1], center[2] + axis[2]))
    if c is None or a is None:
        return None
    return (a[0] - c[0], a[1] - c[1])


# --- Gizmo geometry emission ------------------------------------------------

def _readout():
    if _drag is None:
        return ''
    h = _drag['handle']
    if h in ('rx', 'ry', 'rz', 'rs'):
        lbl = {'rx': '↻X', 'ry': '↻Y', 'rz': '↻Z', 'rs': '↻'}[h]
        return '%s %+.0f°' % (lbl, _drag['deg'])
    if h == 'x':
        return 'ΔX %+.2f Å' % _drag['dx']
    if h == 'y':
        return 'ΔY %+.2f Å' % _drag['dy']
    if h == 'z':
        return 'ΔZ %+.2f Å' % _drag['dz']
    return 'Δ %+.1f, %+.1f, %+.1f Å' % (_drag['dx'], _drag['dy'], _drag['dz'])


def _emit(active=True):
    """Recompute the gizmo geometry for the active object + tool and write it to
    the temp JSON Swift reads back."""
    out = {'active': False}
    try:
        if active and _object_exists(_active):
            params = _view_params(_aspect)
            center = _center()
            if params is not None and center is not None:
                cproj = _project(params, center)
                if cproj is not None:
                    out = {'active': True, 'obj': _active, 'tool': _tool,
                           'center': [cproj[0], cproj[1]], 'readout': _readout()}
                    half_h = cproj[2] * params[5]
                    if _tool == 'translate':
                        out['axes'] = {}
                        for k, ax in _AXES.items():
                            d = _axis_screen_dir(params, center, ax)
                            if d is None:
                                continue
                            n = math.hypot(d[0], d[1])
                            if n < 1e-9:
                                continue
                            s = _AXIS_NDC / n   # world length for target screen length
                            tip = _project(params, (center[0] + ax[0] * s,
                                                    center[1] + ax[1] * s,
                                                    center[2] + ax[2] * s))
                            if tip is not None:
                                out['axes'][k] = [tip[0], tip[1]]
                        # XY plane handle: small offset along world +X and +Y.
                        dxs = _axis_screen_dir(params, center, _AXES['x'])
                        dys = _axis_screen_dir(params, center, _AXES['y'])
                        if dxs and dys:
                            nx = math.hypot(*dxs) or 1.0
                            ny = math.hypot(*dys) or 1.0
                            ph = _project(params,
                                          (center[0] + _AXES['x'][0] * (_PLANE_NDC / nx)
                                           + _AXES['y'][0] * (_PLANE_NDC / ny),
                                           center[1] + _AXES['x'][1] * (_PLANE_NDC / nx)
                                           + _AXES['y'][1] * (_PLANE_NDC / ny),
                                           center[2] + _AXES['x'][2] * (_PLANE_NDC / nx)
                                           + _AXES['y'][2] * (_PLANE_NDC / ny)))
                            if ph is not None:
                                out['plane'] = [ph[0], ph[1]]
                    else:  # rotate: ring polylines
                        out['rings'] = {}
                        r_world = _RING_NDC * half_h
                        for k in ('x', 'y', 'z'):
                            u, vv = _RING_BASIS[k]
                            pts = []
                            for i in range(_RING_SEG + 1):
                                a = 2.0 * math.pi * i / _RING_SEG
                                cu = math.cos(a) * r_world
                                sv = math.sin(a) * r_world
                                p = (center[0] + u[0] * cu + vv[0] * sv,
                                     center[1] + u[1] * cu + vv[1] * sv,
                                     center[2] + u[2] * cu + vv[2] * sv)
                                pr = _project(params, p)
                                if pr is not None:
                                    pts.append([pr[0], pr[1]])
                            out['rings'][k] = pts
                        # Outer screen-rotation ring: a circle in NDC about center.
                        screen = []
                        for i in range(_RING_SEG + 1):
                            a = 2.0 * math.pi * i / _RING_SEG
                            screen.append([cproj[0] + (_RING_NDC + 0.06) * math.cos(a) / max(_aspect, 1e-6),
                                           cproj[1] + (_RING_NDC + 0.06) * math.sin(a)])
                        out['rings']['s'] = screen
    except Exception as e:
        print('METALMOVE_ERR:' + str(e))
        out = {'active': False}
    try:
        with open(_PATH, 'w') as f:
            json.dump(out, f)
    except Exception:
        pass
    print('GIZMO:ready')


# --- Public API (called from Swift) -----------------------------------------

def set_active(obj, tool, aspect):
    """Make `obj` the active object (empty string clears) and emit geometry."""
    global _active, _tool, _aspect
    _aspect = float(aspect)
    _tool = tool if tool in ('translate', 'rotate') else 'translate'
    _active = obj if (obj and _object_exists(obj)) else None
    _emit(_active is not None)


def clear_active():
    global _active
    _active = None
    _emit(False)


def set_tool(tool, aspect):
    global _tool, _aspect
    _aspect = float(aspect)
    _tool = tool if tool in ('translate', 'rotate') else 'translate'
    _emit(_active is not None)


def refresh(aspect):
    """Recompute + re-emit (call when the camera changed)."""
    global _aspect
    _aspect = float(aspect)
    _emit(_active is not None)


def pick_object(ndc_x, ndc_y, aspect):
    """Grab-what-you-touch: set the active object to whatever is under the point
    (clear it on empty space), then emit geometry. Reuses metal_pick."""
    global _active, _aspect
    _aspect = float(aspect)
    try:
        from pymol import metal_pick
        best = metal_pick._pick_atom(ndc_x, ndc_y, aspect)
        _active = best[1] if best is not None else None
    except Exception as e:
        print('METALMOVE_ERR:' + str(e))
        _active = None
    _emit(_active is not None)


def begin_drag(handle, ndc_x, ndc_y, aspect):
    global _drag, _aspect
    _aspect = float(aspect)
    _drag = {'handle': handle, 'px': float(ndc_x), 'py': float(ndc_y),
             'dx': 0.0, 'dy': 0.0, 'dz': 0.0, 'deg': 0.0}
    _emit(_active is not None)


def update_drag(ndc_x, ndc_y, aspect):
    """Apply the incremental pointer move for the in-flight handle drag."""
    global _aspect
    _aspect = float(aspect)
    if _drag is None or not _object_exists(_active):
        return
    dnx = float(ndc_x) - _drag['px']
    dny = float(ndc_y) - _drag['py']
    _drag['px'] = float(ndc_x)
    _drag['py'] = float(ndc_y)
    params = _view_params(aspect)
    center = _center()
    if params is None or center is None:
        return
    h = _drag['handle']
    try:
        if h in ('x', 'y', 'z'):
            ax = _AXES[h]
            d = _axis_screen_dir(params, center, ax)
            if d:
                denom = d[0] * d[0] + d[1] * d[1]
                if denom > 1e-12:
                    dist = (dnx * d[0] + dny * d[1]) / denom   # world Angstrom
                    cmd.translate([ax[0] * dist, ax[1] * dist, ax[2] * dist],
                                  object=_active, camera=0)
                    _drag['dx'] += ax[0] * dist
                    _drag['dy'] += ax[1] * dist
                    _drag['dz'] += ax[2] * dist
        elif h == 'plane':
            dxs = _axis_screen_dir(params, center, _AXES['x'])
            dys = _axis_screen_dir(params, center, _AXES['y'])
            if dxs and dys:
                det = dxs[0] * dys[1] - dxs[1] * dys[0]
                if abs(det) > 1e-12:
                    sx = (dnx * dys[1] - dny * dys[0]) / det
                    sy = (dxs[0] * dny - dxs[1] * dnx) / det
                    cmd.translate([sx, sy, 0.0], object=_active, camera=0)
                    _drag['dx'] += sx
                    _drag['dy'] += sy
        elif h == 'free':
            cproj = _project(params, center)
            if cproj:
                half_h = cproj[2] * params[5]
                half_w = half_h * params[6]
                wx = dnx * half_w
                wy = dny * half_h
                cmd.translate([wx, wy, 0.0], object=_active, camera=1)
                _drag['dx'] += wx
                _drag['dy'] += wy
        elif h in ('rx', 'ry', 'rz', 'rs'):
            cproj = _project(params, center)
            if cproj:
                # Signed screen angle swept about the projected center, prev->cur.
                # (_drag px/py already hold the current point; subtract the delta
                # to recover the previous point.)
                ang_prev = math.atan2((_drag['py'] - dny) - cproj[1], (_drag['px'] - dnx) - cproj[0])
                ang_cur = math.atan2(_drag['py'] - cproj[1], _drag['px'] - cproj[0])
                dtheta = ang_cur - ang_prev
                while dtheta > math.pi:
                    dtheta -= 2 * math.pi
                while dtheta < -math.pi:
                    dtheta += 2 * math.pi
                deg = math.degrees(dtheta)
                if h == 'rs':
                    cmd.rotate('z', deg, object=_active, origin=center, camera=1)
                else:
                    cmd.rotate(h[1], deg, object=_active, origin=center, camera=0)
                _drag['deg'] += deg
    except Exception as e:
        print('METALMOVE_ERR:' + str(e))
    _emit(True)


def end_drag():
    global _drag
    _drag = None
    _emit(_active is not None)


def reset_active():
    """Reset the active object's TTT (matrix_reset) — non-destructive undo."""
    if _object_exists(_active):
        try:
            cmd.matrix_reset(_active, mode=1)
        except Exception as e:
            print('METALMOVE_ERR:' + str(e))
    _emit(_active is not None)


def cleanup():
    """Leave Move mode: clear state. TTT moves that weren't reset are kept (they
    persist in the object and the saved session)."""
    global _active, _drag
    _active = None
    _drag = None
    _emit(False)
