"""Native macOS mouse mode / selection mode panel for PyMOL using PyObjC.

Displays the current mouse configuration, button mapping table,
selection granularity, state info, and transport controls.
Mimics the bottom overlay panel from the original PyMOL internal GUI.

Called from main_appkit.mm after the window is created.
"""

import objc
import AppKit
import Foundation

# ---------------------------------------------------------------------------
# Module-level state
# ---------------------------------------------------------------------------

_cmd = None
_container = None
_text_view = None
_poll_timer = None
_prev_snapshot = None
_retained = []  # prevent GC of ObjC objects

# ---------------------------------------------------------------------------
# Theme colors (dark background, colored monospace text)
# ---------------------------------------------------------------------------

_BG_COLOR = AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(
    0.2, 0.2, 0.2, 1.0)  # #333333
_WHITE = AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(
    1.0, 1.0, 1.0, 1.0)
_GREEN = AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(
    0.3, 1.0, 0.3, 1.0)
_RED = AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(
    1.0, 0.3, 0.3, 1.0)
_YELLOW = AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(
    1.0, 1.0, 0.3, 1.0)
_CYAN = AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(
    0.3, 1.0, 1.0, 1.0)
_MAGENTA = AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(
    1.0, 0.5, 0.8, 1.0)
_GRAY = AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(
    0.6, 0.6, 0.6, 1.0)

_MONO_FONT = None  # set in setup()

# ---------------------------------------------------------------------------
# Selection mode names (indexed by mouse_selection_mode setting)
# ---------------------------------------------------------------------------

_SELECTION_MODE_NAMES = [
    'Atoms',
    'Residues',
    'Chains',
    'Segments',
    'Objects',
    'Molecules',
    'C-alphas',
]

# ---------------------------------------------------------------------------
# Mouse mode data — imported from pymol.controlling at runtime
# ---------------------------------------------------------------------------

def _get_mode_dict():
    """Return the mode_dict from pymol.controlling."""
    try:
        from pymol.controlling import mode_dict
        return mode_dict
    except ImportError:
        return {}


def _get_mode_name_dict():
    """Return the mode_name_dict from pymol.controlling."""
    try:
        from pymol.controlling import mode_name_dict
        return mode_name_dict
    except ImportError:
        return {}


def _get_mouse_ring():
    """Return the current mouse_ring from pymol.controlling."""
    try:
        from pymol.controlling import mouse_ring
        return mouse_ring
    except ImportError:
        return ['three_button_viewing']


# ---------------------------------------------------------------------------
# Build the attributed string for the entire panel
# ---------------------------------------------------------------------------

def _build_panel_text():
    """Build an NSAttributedString representing the full mouse panel."""
    if _cmd is None:
        return None

    try:
        button_mode_name = _cmd.get_setting_string('button_mode_name')
    except Exception:
        button_mode_name = '3-Button Viewing'

    try:
        sel_mode = int(_cmd.get_setting_int('mouse_selection_mode'))
    except Exception:
        sel_mode = 1

    try:
        state = int(_cmd.get('state'))
    except Exception:
        state = 1

    try:
        n_states = int(_cmd.count_states('all'))
    except Exception:
        n_states = 1

    # Determine the current mode key for the button mapping table
    mode_key = None
    mode_dict = _get_mode_dict()
    mode_name_dict = _get_mode_name_dict()

    # Reverse lookup: find mode key from the display name
    for k, v in mode_name_dict.items():
        if v == button_mode_name:
            mode_key = k
            break

    # Fallback: try the mouse_ring
    if mode_key is None:
        try:
            bm = int(_cmd.get_setting_int('button_mode'))
            ring = _get_mouse_ring()
            if 0 <= bm < len(ring):
                mode_key = ring[bm]
            elif bm < 0:
                from pymol.controlling import mode_name_list
                idx = (-1 - bm) % len(mode_name_list)
                mode_key = mode_name_list[idx]
        except Exception:
            pass

    if mode_key is None:
        mode_key = 'three_button_viewing'

    mode_list = mode_dict.get(mode_key, [])

    # Parse mode_list into a lookup: (button, modifier) -> action
    button_map = {}
    for entry in mode_list:
        btn, mod, act = entry[0], entry[1], entry[2]
        button_map[(btn, mod)] = act

    # Selection mode name
    sel_name = _SELECTION_MODE_NAMES[sel_mode] if 0 <= sel_mode < len(
        _SELECTION_MODE_NAMES) else 'Atoms'

    # Now build the attributed string
    result = AppKit.NSMutableAttributedString.alloc().init()

    def _append(text, color):
        attrs = {
            AppKit.NSFontAttributeName: _MONO_FONT,
            AppKit.NSForegroundColorAttributeName: color,
        }
        seg = AppKit.NSAttributedString.alloc().initWithString_attributes_(
            text, attrs)
        result.appendAttributedString_(seg)

    # --- Header: Mouse Mode ---
    _append("Mouse Mode ", _WHITE)
    _append(button_mode_name, _GREEN)
    _append("\n", _WHITE)

    # --- Button mapping table ---
    # Header row
    _append("         L      M      R      Wheel\n", _WHITE)

    # Rows: (modifier_label, modifier_key, color)
    rows = [
        ('     ', 'none', _WHITE),
        ('Shft ', 'shft', _RED),
        ('Ctrl ', 'ctrl', _RED),
        ('CtSh ', 'ctsh', _RED),
    ]

    for label, mod_key, label_color in rows:
        _append(label, label_color)
        for btn in ['l', 'm', 'r', 'w']:
            act = button_map.get((btn, mod_key), 'none')
            act_display = act.capitalize() if act != 'none' else '    '
            # Pad to 7 chars
            act_display = act_display.ljust(7)[:7]
            _append(act_display, _GREEN)
        _append("\n", _WHITE)

    # --- Single/Double click rows ---
    _append("\n", _WHITE)
    _append("SngClk ", _YELLOW)
    for btn in ['single_left', 'single_middle', 'single_right']:
        act = button_map.get((btn, 'none'), 'none')
        act_display = act.capitalize() if act != 'none' else '    '
        act_display = act_display.ljust(7)[:7]
        _append(act_display, _GREEN)
    _append("\n", _WHITE)

    _append("DblClk ", _YELLOW)
    for btn in ['double_left', 'double_middle', 'double_right']:
        act = button_map.get((btn, 'none'), 'none')
        act_display = act.capitalize() if act != 'none' else '    '
        act_display = act_display.ljust(7)[:7]
        _append(act_display, _GREEN)
    _append("\n\n", _WHITE)

    # --- Selection mode ---
    _append("Selecting ", _WHITE)
    _append(sel_name, _CYAN)
    _append("\n", _WHITE)

    # --- State info ---
    _append(f"State {state}/{n_states}", _WHITE)
    _append("\n", _WHITE)

    return result


def _build_snapshot():
    """Return a hashable snapshot of the current state for change detection."""
    if _cmd is None:
        return None
    try:
        button_mode_name = _cmd.get_setting_string('button_mode_name')
        sel_mode = _cmd.get_setting_int('mouse_selection_mode')
        state = _cmd.get('state')
        n_states = _cmd.count_states('all')
        return (button_mode_name, sel_mode, state, n_states)
    except Exception:
        return None


# ---------------------------------------------------------------------------
# Transport button actions
# ---------------------------------------------------------------------------

class _TransportTarget(AppKit.NSObject):
    """Target for transport control buttons."""

    def initWithCommand_(self, command):
        self = objc.super(_TransportTarget, self).init()
        if self is None:
            return None
        self._command = command
        return self

    @objc.typedSelector(b'v@:@')
    def buttonClicked_(self, sender):
        if _cmd is None:
            return
        try:
            cmd_str = self._command
            if cmd_str == 'rewind':
                _cmd.rewind()
            elif cmd_str == 'backward':
                _cmd.backward()
            elif cmd_str == 'forward':
                _cmd.forward()
            elif cmd_str == 'ending':
                _cmd.ending()
            elif cmd_str == 'mplay':
                _cmd.mplay()
            elif cmd_str == 'mstop':
                _cmd.mstop()
            elif cmd_str == 'frame_backward':
                try:
                    f = int(_cmd.get('frame'))
                    _cmd.frame(max(1, f - 1))
                except Exception:
                    pass
            elif cmd_str == 'frame_forward':
                try:
                    f = int(_cmd.get('frame'))
                    _cmd.frame(f + 1)
                except Exception:
                    pass
            elif cmd_str == 'mouse_forward':
                _cmd.mouse(action='forward')
            elif cmd_str == 'mouse_backward':
                _cmd.mouse(action='backward')
            elif cmd_str == 'sel_forward':
                _cmd.mouse(action='select_forward')
            elif cmd_str == 'sel_backward':
                _cmd.mouse(action='select_backward')
        except Exception as e:
            print(f"Mouse panel transport error: {e}")


# ---------------------------------------------------------------------------
# Polling
# ---------------------------------------------------------------------------

class _PollTimerTarget(AppKit.NSObject):
    """Target for the poll timer."""

    @objc.typedSelector(b'v@:@')
    def poll_(self, timer):
        _poll_panel()


def _poll_panel():
    """Poll PyMOL for changes and rebuild the panel text if needed."""
    global _prev_snapshot

    if _cmd is None or _text_view is None:
        return

    snapshot = _build_snapshot()
    if snapshot == _prev_snapshot:
        return
    _prev_snapshot = snapshot

    astr = _build_panel_text()
    if astr is None:
        return

    storage = _text_view.textStorage()
    storage.beginEditing()
    rng = (0, storage.length())
    storage.replaceCharactersInRange_withAttributedString_(rng, astr)
    storage.endEditing()


# ---------------------------------------------------------------------------
# UI building
# ---------------------------------------------------------------------------

_BUTTON_BG = AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(
    0.28, 0.28, 0.30, 1.0)
_BUTTON_TEXT = AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(
    0.9, 0.55, 0.75, 1.0)  # pink/magenta for transport


def _make_transport_button(title, command, frame):
    """Create a small transport control button."""
    btn = AppKit.NSButton.alloc().initWithFrame_(frame)
    btn.setBezelStyle_(AppKit.NSBezelStyleSmallSquare)
    btn.setBordered_(True)
    btn.setWantsLayer_(True)
    btn.layer().setBackgroundColor_(_BUTTON_BG.CGColor())
    btn.layer().setCornerRadius_(2.0)

    attrs = {
        AppKit.NSFontAttributeName: _MONO_FONT or AppKit.NSFont.userFixedPitchFontOfSize_(11),
        AppKit.NSForegroundColorAttributeName: _BUTTON_TEXT,
    }
    astr = AppKit.NSAttributedString.alloc().initWithString_attributes_(
        title, attrs)
    btn.setAttributedTitle_(astr)

    target = _TransportTarget.alloc().initWithCommand_(command)
    _retained.append(target)
    btn.setTarget_(target)
    btn.setAction_(b'buttonClicked:')

    return btn


def _build_transport_bar(parent_view, y_offset, width):
    """Build the row of transport control buttons at the given y offset."""
    btn_h = 22
    padding = 3

    # Transport buttons: |< < > >| Stop Play  MouseMode SelMode
    transport_defs = [
        ('|<',  'rewind'),
        ('<',   'frame_backward'),
        ('>',   'frame_forward'),
        ('>|',  'ending'),
        ('S',   'mstop'),
        ('P',   'mplay'),
        ('M<',  'mouse_backward'),
        ('M>',  'mouse_forward'),
        ('S<',  'sel_backward'),
        ('S>',  'sel_forward'),
    ]

    n = len(transport_defs)
    total_pad = padding * (n + 1)
    btn_w = (width - total_pad) / n
    x = padding

    for title, command in transport_defs:
        frame = ((x, y_offset), (btn_w, btn_h))
        btn = _make_transport_button(title, command, frame)
        btn.setAutoresizingMask_(AppKit.NSViewWidthSizable)
        parent_view.addSubview_(btn)
        x += btn_w + padding

    return btn_h


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def setup(container_view, cmd):
    """Build the mouse panel inside the given NSView container.

    Called from main_appkit.mm after the window is created.
    *container_view* is the NSView designated for the mouse panel.
    *cmd* is the pymol.cmd module.
    """
    global _cmd, _container, _text_view, _poll_timer, _MONO_FONT

    _cmd = cmd
    _container = container_view
    _MONO_FONT = AppKit.NSFont.userFixedPitchFontOfSize_(11)

    bounds = container_view.bounds()
    w = bounds.size.width
    h = bounds.size.height

    container_view.setWantsLayer_(True)
    container_view.layer().setBackgroundColor_(_BG_COLOR.CGColor())

    # Transport buttons at the bottom
    transport_h = _build_transport_bar(container_view, 4, w)

    # Text view above the transport bar showing mouse mode info
    text_y = transport_h + 8
    text_h = h - text_y - 4

    scroll_frame = ((4, text_y), (w - 8, text_h))
    scroll_view = AppKit.NSScrollView.alloc().initWithFrame_(scroll_frame)
    scroll_view.setHasVerticalScroller_(True)
    scroll_view.setHasHorizontalScroller_(False)
    scroll_view.setAutoresizingMask_(
        AppKit.NSViewWidthSizable | AppKit.NSViewHeightSizable)
    scroll_view.setDrawsBackground_(True)
    scroll_view.setBackgroundColor_(_BG_COLOR)
    scroll_view.setBorderType_(AppKit.NSNoBorder)

    content_size = scroll_view.contentSize()
    text_frame = ((0, 0), (content_size.width, content_size.height))
    _text_view = AppKit.NSTextView.alloc().initWithFrame_(text_frame)
    _text_view.setMinSize_((0, content_size.height))
    _text_view.setMaxSize_((1e7, 1e7))
    _text_view.setVerticallyResizable_(True)
    _text_view.setHorizontallyResizable_(False)
    _text_view.setAutoresizingMask_(AppKit.NSViewWidthSizable)
    _text_view.textContainer().setContainerSize_(
        (content_size.width, 1e7))
    _text_view.textContainer().setWidthTracksTextView_(True)

    _text_view.setEditable_(False)
    _text_view.setSelectable_(True)
    _text_view.setRichText_(True)
    _text_view.setBackgroundColor_(_BG_COLOR)
    _text_view.setTextColor_(_WHITE)
    _text_view.setFont_(_MONO_FONT)

    scroll_view.setDocumentView_(_text_view)
    container_view.addSubview_(scroll_view)

    # Initial render
    _poll_panel()

    # Start polling timer (500ms)
    timer_target = _PollTimerTarget.alloc().init()
    _retained.append(timer_target)

    _poll_timer = (
        AppKit.NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
            0.5, timer_target,
            objc.selector(timer_target.poll_, signature=b'v@:@'),
            None, True))

    # Also fire during event tracking so panel stays responsive
    AppKit.NSRunLoop.currentRunLoop().addTimer_forMode_(
        _poll_timer, AppKit.NSRunLoopCommonModes)
