"""Unified molecular-frame Move gizmo for the Metal backend.

One gizmo per active object, anchored on a per-object orthonormal frame derived
from molecular features:

    origin = center of mass
    x      = normalize(Cterm - COM)
    z      = normalize((Nterm - COM) x x)     (perpendicular to the N.COM.C plane)
    y      = z x x                             (right-handed)

Termini are the whole object's first/last polymer CA (atom order = N->C). Objects
with no protein termini fall back to PCA principal axes; a last resort is world
axes. The frame is computed once in the object's LOCAL coordinates and displayed
through the object's current transform (TTT), so it tumbles with the molecule.

The SAME frame drives both translation (drag an axis arrow) and rotation (drag a
ring) — there is no mode switch. All manipulation is non-destructive TTT
(cmd.translate/cmd.rotate with object=); Reset is matrix_reset. Gizmo geometry is
written to <tmpdir>/pymol_gizmo.json, which Swift reads back synchronously.

NDC convention matches metal_pick / the gesture handlers: bottom-left origin,
+x right, +y up, in [-1, 1].
"""
import json
import math
import os
import tempfile

from pymol import cmd

# Module state --------------------------------------------------------------
_active = None          # active object name, or None
_aspect = 1.0           # last viewport aspect (width / height)
_drag = None            # in-flight drag: {handle, px, py, dist, deg, dx, dy}
# Per-object model-space frame: obj -> (com[3], (bx, by, bz)) unit column vectors.
_frame = {}

# Gizmo size is tied to the object's radius (world Angstroms), so it stays
# proportional to the molecule as you zoom, rather than a fixed screen size.
_AXIS_FRAC = 0.65       # axis arrow length as a fraction of the object radius
_RING_FRAC = 0.55       # rotation ring radius as a fraction of the object radius
_MIN_RADIUS = 3.0       # Angstrom floor so tiny objects still get a visible gizmo
_RING_SEG = 48
_ELEM_MASS = {'H': 1.008, 'C': 12.011, 'N': 14.007, 'O': 15.999, 'S': 32.06,
              'P': 30.974, 'FE': 55.845, 'ZN': 65.38, 'MG': 24.305,
              'CA': 40.078, 'NA': 22.99, 'CL': 35.45, 'K': 39.098}
_PATH = os.path.join(tempfile.gettempdir(), 'pymol_gizmo.json')


# --- vector helpers ---------------------------------------------------------

def _sub(a, b):
    return [a[0] - b[0], a[1] - b[1], a[2] - b[2]]


def _cross(a, b):
    return [a[1] * b[2] - a[2] * b[1],
            a[2] * b[0] - a[0] * b[2],
            a[0] * b[1] - a[1] * b[0]]


def _dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def _norm(v):
    n = math.sqrt(_dot(v, v))
    return [v[0] / n, v[1] / n, v[2] / n] if n > 1e-9 else None


# --- View / projection (mirrors metal_pick) --------------------------------

def _view_params(aspect):
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


def _axis_screen_dir(params, center, axis):
    """Screen displacement (ndc) of a 1 Angstrom step along `axis` at `center`."""
    c = _project(params, center)
    a = _project(params, [center[0] + axis[0], center[1] + axis[1], center[2] + axis[2]])
    if c is None or a is None:
        return None
    return (a[0] - c[0], a[1] - c[1])


def _object_exists(obj):
    if not obj:
        return False
    try:
        return obj in (cmd.get_names('objects') or [])
    except Exception:
        return False


# --- Per-object molecular frame --------------------------------------------

def _model_com(obj):
    """Mass-weighted center of mass in MODEL (untransformed) coordinates."""
    acc = [0.0, 0.0, 0.0, 0.0]
    try:
        cmd.iterate_state(
            1, '(%s)' % obj,
            'm = MASS.get(elem.upper(), 12.0); '
            'acc[0] += m * x; acc[1] += m * y; acc[2] += m * z; acc[3] += m',
            space={'acc': acc, 'MASS': _ELEM_MASS})
    except Exception:
        return None
    if acc[3] <= 0:
        return None
    return [acc[0] / acc[3], acc[1] / acc[3], acc[2] / acc[3]]


def _termini(obj):
    """(N-term CA, C-term CA) in model coords — first/last polymer CA in atom
    order (files run N->C). None if fewer than two CAs."""
    cas = []
    try:
        cmd.iterate_state(1, '(%s) and polymer and name CA' % obj,
                          'cas.append((x, y, z))', space={'cas': cas})
    except Exception:
        return None
    if len(cas) < 2:
        return None
    return (list(cas[0]), list(cas[-1]))


def _jacobi3(A):
    """Eigenpairs of a symmetric 3x3 matrix (Jacobi), sorted by descending value.
    Returns [(eigenvalue, eigenvector), ...]."""
    a = [[A[i][j] for j in range(3)] for i in range(3)]
    v = [[1.0 if i == j else 0.0 for j in range(3)] for i in range(3)]
    for _ in range(100):
        p, q, off = 0, 1, abs(a[0][1])
        for (i, j) in ((0, 2), (1, 2)):
            if abs(a[i][j]) > off:
                p, q, off = i, j, abs(a[i][j])
        if off < 1e-14:
            break
        if abs(a[p][p] - a[q][q]) < 1e-18:
            theta = math.pi / 4.0
        else:
            theta = 0.5 * math.atan2(2.0 * a[p][q], a[p][p] - a[q][q])
        c = math.cos(theta); s = math.sin(theta)
        for k in range(3):              # A = J^T A
            akp = a[k][p]; akq = a[k][q]
            a[k][p] = c * akp + s * akq
            a[k][q] = -s * akp + c * akq
        for k in range(3):              # A = A J
            apk = a[p][k]; aqk = a[q][k]
            a[p][k] = c * apk + s * aqk
            a[q][k] = -s * apk + c * aqk
        for k in range(3):              # V = V J
            vkp = v[k][p]; vkq = v[k][q]
            v[k][p] = c * vkp + s * vkq
            v[k][q] = -s * vkp + c * vkq
    eig = [(a[i][i], [v[0][i], v[1][i], v[2][i]]) for i in range(3)]
    eig.sort(key=lambda e: -e[0])
    return eig


def _pca_axes(obj, com):
    """Principal axes (orthonormal, right-handed) of the object's coordinates."""
    C = [[0.0] * 3 for _ in range(3)]
    n = [0]
    try:
        cmd.iterate_state(
            1, '(%s)' % obj,
            'a = x - COM[0]; b = y - COM[1]; c = z - COM[2]; '
            'C[0][0] += a * a; C[0][1] += a * b; C[0][2] += a * c; '
            'C[1][1] += b * b; C[1][2] += b * c; C[2][2] += c * c; n[0] += 1',
            space={'C': C, 'COM': com, 'n': n, 'a': 0, 'b': 0, 'c': 0})
    except Exception:
        return None
    if n[0] < 3:
        return None
    C[1][0] = C[0][1]; C[2][0] = C[0][2]; C[2][1] = C[1][2]
    eig = _jacobi3(C)
    x = _norm(eig[0][1]); y = _norm(eig[1][1]); z = _norm(eig[2][1])
    if not (x and y and z):
        return None
    if _dot(_cross(x, y), z) < 0:   # enforce right-handed
        z = [-c for c in z]
    return (x, y, z)


def _compute_frame(obj):
    com = _model_com(obj)
    if com is None:
        return None
    basis = None
    t = _termini(obj)
    if t is not None:
        nterm, cterm = t
        x = _norm(_sub(cterm, com))
        if x is not None:
            z = _norm(_cross(_sub(nterm, com), x))
            if z is not None:
                basis = (x, _cross(z, x), z)
    if basis is None:
        basis = _pca_axes(obj, com)
    if basis is None:
        basis = ([1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0])
    # Object radius = max distance from the COM to any atom (bounding radius).
    r2 = [0.0]
    try:
        cmd.iterate_state(
            1, '(%s)' % obj,
            'd = (x - COM[0])**2 + (y - COM[1])**2 + (z - COM[2])**2; '
            'r2[0] = d if d > r2[0] else r2[0]',
            space={'r2': r2, 'COM': com, 'd': 0})
    except Exception:
        pass
    radius = max(math.sqrt(r2[0]), _MIN_RADIUS)
    return (com, basis, radius)


def _ensure_frame(obj):
    if obj and obj not in _frame:
        f = _compute_frame(obj)
        if f is not None:
            _frame[obj] = f
    return _frame.get(obj)


def _displayed_frame(obj):
    """(com_world, (dx, dy, dz)) — the model frame transformed by the object's
    current matrix (TTT), so it tumbles with the molecule. None if unavailable."""
    f = _ensure_frame(obj)
    if f is None:
        return None
    com, (bx, by, bz), radius = f
    try:
        m = cmd.get_object_matrix(obj)
    except Exception:
        m = None
    if m and len(m) >= 16:
        def rot(v):
            return [m[0] * v[0] + m[1] * v[1] + m[2] * v[2],
                    m[4] * v[0] + m[5] * v[1] + m[6] * v[2],
                    m[8] * v[0] + m[9] * v[1] + m[10] * v[2]]
        comw = [m[0] * com[0] + m[1] * com[1] + m[2] * com[2] + m[3],
                m[4] * com[0] + m[5] * com[1] + m[6] * com[2] + m[7],
                m[8] * com[0] + m[9] * com[1] + m[10] * com[2] + m[11]]
        return (comw, (rot(bx), rot(by), rot(bz)), radius)
    return (com, (bx, by, bz), radius)


# --- Gizmo geometry emission ------------------------------------------------

def _readout():
    if _drag is None:
        return ''
    h = _drag['handle']
    if h in ('rx', 'ry', 'rz'):
        return '↻%s %+.0f°' % (h[1].upper(), _drag['deg'])
    if h in ('x', 'y', 'z'):
        return 'Δ%s %+.2f Å' % (h.upper(), _drag['dist'])
    return 'Δ %+.1f, %+.1f Å' % (_drag['dx'], _drag['dy'])


def _emit(active=True):
    out = {'active': False}
    try:
        if active and _object_exists(_active):
            params = _view_params(_aspect)
            df = _displayed_frame(_active)
            if params is not None and df is not None:
                com, (dx, dy, dz), radius = df
                cproj = _project(params, com)
                if cproj is not None:
                    out = {'active': True, 'obj': _active,
                           'center': [cproj[0], cproj[1]], 'readout': _readout()}
                    axes = {'x': dx, 'y': dy, 'z': dz}
                    # Axis arrows sized in world units (fraction of the radius).
                    axis_len = _AXIS_FRAC * radius
                    out['axes'] = {}
                    for k, av in axes.items():
                        tip = _project(params, [com[i] + av[i] * axis_len for i in range(3)])
                        if tip is not None:
                            out['axes'][k] = [tip[0], tip[1]]
                    # Rotation rings: one per axis, in the plane of the other two.
                    ringbasis = {'x': (dy, dz), 'y': (dz, dx), 'z': (dx, dy)}
                    r_world = _RING_FRAC * radius
                    out['rings'] = {}
                    for k, (u, vv) in ringbasis.items():
                        pts = []
                        for i in range(_RING_SEG + 1):
                            ang = 2.0 * math.pi * i / _RING_SEG
                            cu = math.cos(ang) * r_world
                            sv = math.sin(ang) * r_world
                            p = [com[j] + u[j] * cu + vv[j] * sv for j in range(3)]
                            pr = _project(params, p)
                            if pr is not None:
                                pts.append([pr[0], pr[1]])
                        out['rings'][k] = pts
    except Exception as e:
        print('METALMOVE_ERR:' + str(e))
        out = {'active': False}
    try:
        with open(_PATH, 'w') as f:
            json.dump(out, f)
    except Exception:
        pass
    print('GIZMO:ready')


# --- Public API (called from Swift) ----------------------------------------

def set_active(obj, aspect):
    """Make `obj` the active object (empty string clears) and emit geometry."""
    global _active, _aspect
    _aspect = float(aspect)
    _active = obj if (obj and _object_exists(obj)) else None
    if _active:
        _ensure_frame(_active)
    _emit(_active is not None)


def clear_active():
    global _active
    _active = None
    _emit(False)


def refresh(aspect):
    global _aspect
    _aspect = float(aspect)
    _emit(_active is not None)


def pick_object(ndc_x, ndc_y, aspect):
    """Grab-what-you-touch: set the active object under the point (clear on empty
    space), compute its frame, emit."""
    global _active, _aspect
    _aspect = float(aspect)
    try:
        from pymol import metal_pick
        best = metal_pick._pick_atom(ndc_x, ndc_y, aspect)
        _active = best[1] if best is not None else None
    except Exception as e:
        print('METALMOVE_ERR:' + str(e))
        _active = None
    if _active:
        _ensure_frame(_active)
    _emit(_active is not None)


def begin_drag(handle, ndc_x, ndc_y, aspect):
    global _drag, _aspect
    _aspect = float(aspect)
    _drag = {'handle': handle, 'px': float(ndc_x), 'py': float(ndc_y),
             'dist': 0.0, 'deg': 0.0, 'dx': 0.0, 'dy': 0.0}
    _emit(_active is not None)


def update_drag(ndc_x, ndc_y, aspect):
    global _aspect
    _aspect = float(aspect)
    if _drag is None or not _object_exists(_active):
        return
    dnx = float(ndc_x) - _drag['px']
    dny = float(ndc_y) - _drag['py']
    _drag['px'] = float(ndc_x)
    _drag['py'] = float(ndc_y)
    params = _view_params(aspect)
    df = _displayed_frame(_active)
    if params is None or df is None:
        return
    com, (dx, dy, dz), _radius = df
    axes = {'x': dx, 'y': dy, 'z': dz}
    h = _drag['handle']
    try:
        if h in ('x', 'y', 'z'):
            av = axes[h]
            d = _axis_screen_dir(params, com, av)
            if d:
                denom = d[0] * d[0] + d[1] * d[1]
                if denom > 1e-12:
                    dist = (dnx * d[0] + dny * d[1]) / denom   # world Angstrom
                    cmd.translate([av[0] * dist, av[1] * dist, av[2] * dist],
                                  object=_active, camera=0)
                    _drag['dist'] += dist
        elif h in ('rx', 'ry', 'rz'):
            av = axes[h[1]]
            cproj = _project(params, com)
            if cproj:
                ang_prev = math.atan2((_drag['py'] - dny) - cproj[1],
                                      (_drag['px'] - dnx) - cproj[0])
                ang_cur = math.atan2(_drag['py'] - cproj[1], _drag['px'] - cproj[0])
                dtheta = ang_cur - ang_prev
                while dtheta > math.pi:
                    dtheta -= 2 * math.pi
                while dtheta < -math.pi:
                    dtheta += 2 * math.pi
                deg = math.degrees(dtheta)
                cmd.rotate([av[0], av[1], av[2]], deg, object=_active,
                           origin=com, camera=0)
                _drag['deg'] += deg
        elif h == 'free':
            cproj = _project(params, com)
            if cproj:
                half_h = cproj[2] * params[5]
                half_w = half_h * params[6]
                wx = dnx * half_w
                wy = dny * half_h
                cmd.translate([wx, wy, 0.0], object=_active, camera=1)
                _drag['dx'] += wx
                _drag['dy'] += wy
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
    """Leave Move mode: clear state + the frame cache. TTT moves persist."""
    global _active, _drag
    _active = None
    _drag = None
    _frame.clear()
    _emit(False)
