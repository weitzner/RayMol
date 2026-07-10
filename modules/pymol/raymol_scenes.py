"""Per-scene render-settings snapshot for RayMol.

Classic PyMOL scenes store the camera + representations + colors but NOT setting
values, so the depth-of-field / lighting / metal_* render "look" is not captured
by `scene ... store` (that's why e.g. metal_dof_aperture didn't persist per
scene). This module snapshots those render settings when a scene is stored/updated
and re-applies them on recall, keyed by scene name, and persists them in the .pse
via registered session save/restore tasks (see cmd._deferred_init_pymol_internals).

Camera lens / zoom / orthographic / FOV are already restored by the scene's saved
view, so they're intentionally NOT captured here (the view owns them).

Driven from the RayMol Scenes UI, which pairs each `scene ... <action>` command
with the matching call below (snapshot_current after store/update; apply/
apply_current after recall/prev/next; prune after delete; clear_all after clear).
"""
from pymol import cmd

# Render "look" settings a scene captures. All are get/set-able globals.
CAPTURE = [
    "metal_raytrace", "metal_rt_shadows", "metal_shadows", "metal_ssao",
    "metal_rt_samples", "metal_rt_ao_radius", "metal_rt_ao_intensity",
    "metal_rt_shadow_intensity", "metal_outline", "metal_outline_width",
    "metal_msaa", "metal_tonemap", "metal_exposure", "metal_sss_wrap",
    "metal_dof", "metal_dof_focus", "metal_dof_range", "metal_dof_aperture",
    "metal_dof_quality", "metal_dof_autofocus", "metal_temporal_ao",
    "metal_upscale", "depth_cue", "fog", "surface_quality",
    "ambient", "direct", "reflect", "specular", "shininess",
    "ray_opaque_background",
]

# {scene_name: {setting: value}} — persisted into the .pse via session tasks.
_scene_settings = {}


def _current(_self=cmd):
    try:
        return _self.get("scene_current_name") or ""
    except Exception:
        return ""


def _capture(_self=cmd):
    out = {}
    for s in CAPTURE:
        try:
            out[s] = _self.get(s)
        except Exception:
            pass   # setting absent in this build — skip
    return out


def snapshot_current(_self=cmd):
    """Capture the current render settings for the current scene. Call right
    after `scene new, store` or `scene auto, update`."""
    name = _current(_self)
    if name:
        _scene_settings[name] = _capture(_self)
    return name


def apply(name, _self=cmd):
    """Re-apply scene `name`'s captured render settings. Call right after
    `scene <name>, recall`."""
    d = _scene_settings.get(name)
    if not d:
        return
    for s, v in d.items():
        try:
            _self.set(s, v)
        except Exception:
            pass


def apply_current(_self=cmd):
    """Apply the now-current scene's settings (after prev/next navigation)."""
    apply(_current(_self), _self)


def prune(_self=cmd):
    """Drop snapshots for scenes that no longer exist (call after a delete)."""
    try:
        live = set(_self.get_scene_list() or [])
    except Exception:
        return
    for name in list(_scene_settings.keys()):
        if name not in live:
            _scene_settings.pop(name, None)


def clear_all(_self=cmd):
    """Forget all snapshots (call after `scene *, clear`)."""
    _scene_settings.clear()


# --- .pse persistence (registered in cmd._deferred_init_pymol_internals) ---
def session_save(session, *, _self=cmd):
    session["raymol_scene_settings"] = dict(_scene_settings)
    return 1


def session_restore(session, *, _self=cmd):
    _scene_settings.clear()
    d = session.get("raymol_scene_settings")
    if isinstance(d, dict):
        _scene_settings.update(d)
    return 1
