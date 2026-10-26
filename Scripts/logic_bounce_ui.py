#!/usr/bin/env python3
from __future__ import annotations

import subprocess
import time
from ctypes import CDLL, POINTER, Structure, byref, c_bool, c_double, c_int64, c_size_t, c_uint16, c_uint32, c_uint64, c_void_p
from collections.abc import Callable
from typing import Final, Literal, NoReturn, Optional, TypedDict, Union

from logic_variants import (
    activate_logic,
    logic_process_osa,
    logic_process_osa_action,
    logic_process_osa_action_with_runner,
    logic_process_osa_with_runner,
)
from logic_ui_jxa import bounce_project_snapshot_source, parse_jxa_json_result, run_jxa, save_panel_snapshot_source


RunJxa = Callable[..., subprocess.CompletedProcess[str]]
RunOsa = Callable[[str, float], str]


OSA_TIMEOUT_SEC: Final = 8.0
# Logic's own labels, in every language Logic ships, generated from AXLocalePolicy by
# `Scripts/locale_labels.py --write` and installed beside this file. They were six hand-typed
# tables here -- English and Korean, two of ten -- in a file `Scripts/install.sh` INSTALLS, so the
# bounce flow worked in two languages and no locale guard scanned it (#919).
from logic_ui_labels import (  # noqa: F401  (re-exported under the names this module used)
    BOUNCE_CONFIRM_BUTTONS,
    BOUNCE_DIALOG_KEYWORDS,
    BOUNCE_PROJECT_OR_SECTION,
    BOUNCE_SETTINGS_MARKERS,
    FILE_MENU_BAR_ITEM,
    SAVE_PANEL_CANCEL_BUTTONS,
    SAVE_PANEL_CONFIRM_BUTTONS,
)

# SAVE_PANEL_NAME_LABELS IS GONE, and that is the fix rather than an omission.
#
# It held the macOS save panel's field label -- `save as:` and two Korean spellings. AppKit owns
# that string, not Logic, so it is absent from all 24 corpora by construction and no LabelSet can
# carry it: the canon axis covers Logic's bundle and this panel is not Logic's.
#
# It sat in an AND with three other signals, so a two-language term capped the whole predicate at
# two languages. What actually identifies the panel is the BOUNCE button -- a save panel with a
# button named Bounce is this one -- and that is now seven languages. Dropping the label makes the
# identification work in every language those three signals do; keeping it made them all pointless
# outside English and Korean.
KCG_HID_EVENT_TAP: Final = 0
KCG_EVENT_LEFT_MOUSE_DOWN: Final = 1
KCG_EVENT_LEFT_MOUSE_UP: Final = 2
KCG_EVENT_KEYBOARD_DOWN: Final = True
KCG_EVENT_KEYBOARD_UP: Final = False
KCG_MOUSE_BUTTON_LEFT: Final = 0
KCG_MOUSE_EVENT_CLICK_STATE: Final = 1
KCG_EVENT_FLAG_MASK_SHIFT: Final = 0x00020000
KCG_EVENT_FLAG_MASK_CONTROL: Final = 0x00040000
KCG_EVENT_FLAG_MASK_ALTERNATE: Final = 0x00080000
KCG_EVENT_FLAG_MASK_COMMAND: Final = 0x00100000
MODIFIER_FLAGS: Final[dict[str, int]] = {
    "cmd": KCG_EVENT_FLAG_MASK_COMMAND,
    "command": KCG_EVENT_FLAG_MASK_COMMAND,
    "shift": KCG_EVENT_FLAG_MASK_SHIFT,
    "alt": KCG_EVENT_FLAG_MASK_ALTERNATE,
    "option": KCG_EVENT_FLAG_MASK_ALTERNATE,
    "ctrl": KCG_EVENT_FLAG_MASK_CONTROL,
    "control": KCG_EVENT_FLAG_MASK_CONTROL,
}
KEY_CODES: Final[dict[str, int]] = {
    "a": 0x00,
    "delete": 0x33,
    "return": 0x24,
    "enter": 0x24,
    "escape": 0x35,
    "esc": 0x35,
    "space": 0x31,
    "tab": 0x30,
}


class ControlRow(TypedDict, total=False):
    role: str
    name: str
    value: str
    depth: int


class SavePanelSnapshotOk(TypedDict):
    status: Literal["ok"]
    button_names: list[str]
    text_field_names: list[str]
    text_field_count: int
    static_texts: list[str]
    #: Document-ordered AXStaticText / AXPopUpButton / AXCheckBox rows, when the walker reported
    #: them. Absent on a snapshot recorded before the control rows existed, which is why every
    #: reader treats a missing list as "not reported" rather than "the dialog has no controls".
    controls: list[ControlRow]


class SavePanelSnapshotMissingFrontWindow(TypedDict):
    status: Literal["missing_front_window"]


class SavePanelSnapshotErrorBase(TypedDict):
    status: Literal["error"]


class SavePanelSnapshotError(SavePanelSnapshotErrorBase, total=False):
    reason: str
    stderr: str
    stdout: str


SavePanelSnapshot = Union[
    SavePanelSnapshotOk,
    SavePanelSnapshotMissingFrontWindow,
    SavePanelSnapshotError,
]


class BounceFocusDiagnostics(TypedDict):
    frontmost_app: Optional[str]
    logic_front_window: Optional[str]
    logic_front_sheet: Optional[str]
    logic_window_names: list[str]
    save_panel_snapshot: SavePanelSnapshot


class CGPoint(Structure):
    _fields_ = [("x", c_double), ("y", c_double)]


class NativeCGEventDriver:
    def __init__(self) -> None:
        app_services = CDLL("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices")
        core_foundation = CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")

        self._mouse_event = app_services.CGEventCreateMouseEvent
        self._mouse_event.argtypes = [c_void_p, c_uint32, CGPoint, c_uint32]
        self._mouse_event.restype = c_void_p

        self._keyboard_event = app_services.CGEventCreateKeyboardEvent
        self._keyboard_event.argtypes = [c_void_p, c_uint16, c_bool]
        self._keyboard_event.restype = c_void_p

        self._keyboard_unicode = app_services.CGEventKeyboardSetUnicodeString
        self._keyboard_unicode.argtypes = [c_void_p, c_size_t, POINTER(c_uint16)]
        self._keyboard_unicode.restype = None

        self._set_integer = app_services.CGEventSetIntegerValueField
        self._set_integer.argtypes = [c_void_p, c_uint32, c_int64]
        self._set_integer.restype = None

        self._set_flags = app_services.CGEventSetFlags
        self._set_flags.argtypes = [c_void_p, c_uint64]
        self._set_flags.restype = None

        self._post = app_services.CGEventPost
        self._post.argtypes = [c_uint32, c_void_p]
        self._post.restype = None

        self._release = core_foundation.CFRelease
        self._release.argtypes = [c_void_p]
        self._release.restype = None

        self._held_flags = 0

    def click(self, x: int, y: int) -> bool:
        point = CGPoint(float(x), float(y))
        return self._post_mouse(KCG_EVENT_LEFT_MOUSE_DOWN, point) and self._post_mouse(KCG_EVENT_LEFT_MOUSE_UP, point)

    def key_down(self, key: str) -> bool:
        flag = MODIFIER_FLAGS.get(key.lower())
        if flag is None:
            return self._post_key_name(key, key_down=True)
        self._held_flags |= flag
        return True

    def key_up(self, key: str) -> bool:
        flag = MODIFIER_FLAGS.get(key.lower())
        if flag is None:
            return self._post_key_name(key, key_down=False)
        self._held_flags &= ~flag
        return True

    def key_press(self, key: str) -> bool:
        return self._post_key_name(key, key_down=True) and self._post_key_name(key, key_down=False)

    def reset_modifiers(self) -> None:
        self._held_flags = 0

    def type_text(self, text: str) -> bool:
        for character in text:
            if self._held_flags:
                key_code = KEY_CODES.get(character.lower())
                if key_code is None:
                    return False
                if not self._post_key_code(key_code, key_down=True) or not self._post_key_code(key_code, key_down=False):
                    return False
                continue
            if not self._post_unicode_character(character):
                return False
        return True

    def _post_mouse(self, event_type: int, point: CGPoint) -> bool:
        event = self._mouse_event(None, event_type, point, KCG_MOUSE_BUTTON_LEFT)
        if not event:
            return False
        try:
            self._set_integer(event, KCG_MOUSE_EVENT_CLICK_STATE, 1)
            self._post(KCG_HID_EVENT_TAP, event)
            return True
        finally:
            self._release(event)

    def _post_key_name(self, key: str, *, key_down: bool) -> bool:
        key_code = KEY_CODES.get(key.lower())
        if key_code is None:
            return False
        return self._post_key_code(key_code, key_down=key_down)

    def _post_key_code(self, key_code: int, *, key_down: bool) -> bool:
        event = self._keyboard_event(None, c_uint16(key_code), key_down)
        if not event:
            return False
        try:
            self._set_flags(event, c_uint64(self._held_flags))
            self._post(KCG_HID_EVENT_TAP, event)
            return True
        finally:
            self._release(event)

    def _post_unicode_character(self, character: str) -> bool:
        encoded = character.encode("utf-16-le")
        units = (c_uint16 * (len(encoded) // 2)).from_buffer_copy(encoded)
        down = self._keyboard_event(None, 0, KCG_EVENT_KEYBOARD_DOWN)
        up = self._keyboard_event(None, 0, KCG_EVENT_KEYBOARD_UP)
        if not down or not up:
            if down:
                self._release(down)
            if up:
                self._release(up)
            return False
        try:
            self._keyboard_unicode(down, len(units), units)
            self._keyboard_unicode(up, len(units), units)
            self._post(KCG_HID_EVENT_TAP, down)
            self._post(KCG_HID_EVENT_TAP, up)
            return True
        finally:
            self._release(down)
            self._release(up)


_NATIVE_DRIVER: NativeCGEventDriver | None = None


def _native_driver() -> NativeCGEventDriver:
    global _NATIVE_DRIVER
    if _NATIVE_DRIVER is None:
        _NATIVE_DRIVER = NativeCGEventDriver()
    return _NATIVE_DRIVER


def send_ui_events(*commands: str, driver: NativeCGEventDriver | None = None) -> bool:
    event_driver = driver if driver is not None else _native_driver()
    try:
        for command in commands:
            prefix, separator, payload = command.partition(":")
            if separator != ":":
                return False
            if prefix == "c":
                try:
                    x_raw, y_raw = payload.split(",", 1)
                    if not event_driver.click(int(x_raw), int(y_raw)):
                        return False
                except ValueError:
                    return False
            elif prefix == "kd":
                if not event_driver.key_down(payload):
                    return False
            elif prefix == "ku":
                if not event_driver.key_up(payload):
                    return False
            elif prefix == "kp":
                if not event_driver.key_press(payload):
                    return False
            elif prefix == "t":
                if not event_driver.type_text(payload):
                    return False
            else:
                return False
        return True
    finally:
        event_driver.reset_modifiers()


def osa(script: str, timeout: float = OSA_TIMEOUT_SEC) -> str:
    try:
        result = subprocess.run(
            ["/usr/bin/osascript", "-e", script],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return ""
    return result.stdout.strip()


def _process_body(
    body: str,
    *,
    run_osa: RunOsa = osa,
    timeout_sec: float = OSA_TIMEOUT_SEC,
    action: bool = False,
) -> str:
    if action:
        if run_osa is osa:
            logic_process_osa_action(body, timeout_sec=timeout_sec)
            return ""
        return logic_process_osa_action_with_runner(body, run_osa, timeout_sec=timeout_sec)
    if run_osa is osa:
        return logic_process_osa(body, timeout_sec=timeout_sec)
    return logic_process_osa_with_runner(body, run_osa, timeout_sec=timeout_sec)


def _logic_front_container_name(container: str, run_osa: RunOsa = osa) -> str:
    return _process_body(
        f"""try
    return name of {container}
on error
    return ""
end try""",
        run_osa=run_osa,
    )


def logic_front_window_name(run_osa: RunOsa = osa) -> str: return _logic_front_container_name("front window", run_osa)


def logic_front_sheet_name(run_osa: RunOsa = osa) -> str: return _logic_front_container_name("sheet 1 of front window", run_osa)


def bounce_dialog_present(run_osa: RunOsa = osa) -> bool:
    hay = " ".join(
        name.lower()
        for name in (logic_front_window_name(run_osa), logic_front_sheet_name(run_osa))
        if name
    )
    return any(keyword in hay for keyword in BOUNCE_DIALOG_KEYWORDS)


def bounce_project_identity(run_jxa_fn: RunJxa = run_jxa) -> Optional[tuple[int, str]]:
    """Positive saved-project observation; dialogs, sheets and failed reads stay unknown."""
    try:
        result = run_jxa_fn(bounce_project_snapshot_source())
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    snapshot = parse_jxa_json_result(result)
    pid = snapshot.get("process_id")
    document = snapshot.get("document")
    if (snapshot.get("status") != "ok" or snapshot.get("role") != "AXWindow"
            or snapshot.get("subrole") != "AXStandardWindow"
            or type(snapshot.get("sheet_count")) is not int or snapshot["sheet_count"] != 0
            or type(pid) is not int or pid <= 0
            or not isinstance(document, str) or not document.startswith("file:///")):
        return None
    return pid, document


def _string_items(values) -> list[str]:
    if isinstance(values, list):
        return [value.strip() for value in values if isinstance(value, str) and value.strip()]
    return []


def _control_items(values) -> list[ControlRow]:
    """Coerce the walker's control rows, dropping anything that is not a row.

    A row keeps its raw `name` and `value` — including empty strings — because "the control is
    here and its value read empty" is a reading, and dropping it would turn that into "no control".
    """
    rows: list[ControlRow] = []
    if not isinstance(values, list):
        return rows
    for value in values:
        if not isinstance(value, dict):
            continue
        role = value.get("role")
        if not isinstance(role, str) or not role:
            continue
        name = value.get("name")
        raw_value = value.get("value")
        depth = value.get("depth")
        rows.append({
            "role": role,
            "name": name.strip() if isinstance(name, str) else "",
            "value": raw_value.strip() if isinstance(raw_value, str) else "",
            "depth": depth if isinstance(depth, int) else 0,
        })
    return rows


def _unreachable_status(status: str) -> NoReturn: raise AssertionError(f"unexpected snapshot status: {status}")


def _coerce_save_panel_snapshot(raw_snapshot) -> SavePanelSnapshot:
    if not isinstance(raw_snapshot, dict):
        return {"status": "error", "reason": "invalid_snapshot_payload"}

    status = raw_snapshot.get("status")
    if status == "ok":
        text_field_count = raw_snapshot.get("text_field_count")
        return {
            "status": "ok",
            "button_names": _string_items(raw_snapshot.get("button_names")),
            "text_field_names": _string_items(raw_snapshot.get("text_field_names")),
            "text_field_count": text_field_count if isinstance(text_field_count, int) else 0,
            "static_texts": _string_items(raw_snapshot.get("static_texts")),
            "controls": _control_items(raw_snapshot.get("controls")),
        }
    if status == "missing_front_window":
        return {"status": "missing_front_window"}
    if status == "error":
        snapshot: SavePanelSnapshotError = {"status": "error"}
        reason = raw_snapshot.get("reason")
        stderr = raw_snapshot.get("stderr")
        stdout = raw_snapshot.get("stdout")
        if isinstance(reason, str) and reason:
            snapshot["reason"] = reason
        if isinstance(stderr, str) and stderr:
            snapshot["stderr"] = stderr
        if isinstance(stdout, str) and stdout:
            snapshot["stdout"] = stdout
        return snapshot
    return {"status": "error", "reason": "invalid_snapshot_payload"}


def save_panel_snapshot(run_jxa_fn: RunJxa = run_jxa) -> SavePanelSnapshot:
    try:
        result = run_jxa_fn(save_panel_snapshot_source())
    except (FileNotFoundError, subprocess.TimeoutExpired) as error:
        return {"status": "error", "reason": "jxa_probe_failed", "stderr": str(error)}
    return _coerce_save_panel_snapshot(parse_jxa_json_result(result))


def _normalized_strings(values: list[str]) -> list[str]:
    """AX readings, lowercased, to be compared against the generated tables.

    `logic_ui_labels` emits its values already folded, so every comparison in this file is
    folded-against-folded and no call site has to remember to lower one side. One did and one did
    not before the tables were generated, which is the shape of inconsistency that works until the
    day a label has a capital in one language and not another.
    """
    return [value.lower() for value in values]


def save_panel_present(run_jxa_fn: RunJxa = run_jxa) -> bool:
    snapshot = save_panel_snapshot(run_jxa_fn=run_jxa_fn)
    status = snapshot["status"]
    if status == "ok":
        button_names, text_field_names, static_texts, has_text_field = _snapshot_parts(snapshot)
        has_confirm = any(label in button_names for label in SAVE_PANEL_CONFIRM_BUTTONS)
        has_cancel = any(label in button_names for label in SAVE_PANEL_CANCEL_BUTTONS)
        del text_field_names, static_texts
        return has_text_field and has_confirm and has_cancel
    if status == "error" or status == "missing_front_window":
        return False
    return _unreachable_status(status)


def _snapshot_parts(snapshot: SavePanelSnapshotOk) -> tuple[list[str], list[str], list[str], bool]:
    button_names = _normalized_strings(snapshot["button_names"])
    text_field_names = _normalized_strings(snapshot["text_field_names"])
    static_texts = _normalized_strings(snapshot["static_texts"])
    return button_names, text_field_names, static_texts, bool(text_field_names) or snapshot["text_field_count"] > 0


def bounce_settings_present(run_jxa_fn: RunJxa = run_jxa) -> bool:
    snapshot = save_panel_snapshot(run_jxa_fn=run_jxa_fn)
    status = snapshot["status"]
    if status == "ok":
        button_names, _, static_texts, has_text_field = _snapshot_parts(snapshot)
        has_confirm = any(label in button_names for label in BOUNCE_CONFIRM_BUTTONS)
        has_cancel = any(label in button_names for label in SAVE_PANEL_CANCEL_BUTTONS)
        has_marker = any(any(marker in text for marker in BOUNCE_SETTINGS_MARKERS) for text in static_texts)
        return not has_text_field and has_confirm and has_cancel and has_marker
    if status == "error" or status == "missing_front_window":
        return False
    return _unreachable_status(status)


#: Substrings that identify the dialog's Normalize row across the locales Logic ships. Taken from
#: the same generated table the presence check uses; this list only narrows it to that one row.
NORMALIZE_LABEL_MARKERS: Final[tuple[str, ...]] = (
    "normalize", "normalise", "normalisier", "normaliz", "normalizza", "normali",
    "ノーマライズ", "標準化", "正常化", "노멀라이즈",
)

#: A popup or checkbox value that means "off". Deliberately small: anything not clearly off is
#: reported as `unknown`, and a caller that cannot classify a reading must not treat it as consent.
OFF_VALUES: Final[frozenset[str]] = frozenset({"off", "0", "false", "unchecked", "no", "disabled"})
ON_VALUES: Final[frozenset[str]] = frozenset({"on", "1", "true", "checked", "yes", "enabled"})
OVERLOAD_MARKERS: Final[tuple[str, ...]] = ("overload",)


def bounce_settings_readback(run_jxa_fn: RunJxa = run_jxa) -> dict[str, str]:
    """Row label -> observed value for every popup and checkbox in the Bounce dialog.

    The label is the nearest PRECEDING AXStaticText at the same or a shallower depth in document
    order — the row/label split measured for the Compressor's Controls view, where the name is the
    AXRow's static text and the control itself carries only a value. A control with no such label is
    keyed by its own name; a control with neither is dropped, so a caller sees a missing key rather
    than an invented one.

    Returns `{}` when the snapshot failed. That is "not read", which is a different answer from
    "read and empty", and the helper reports the difference.
    """
    snapshot = save_panel_snapshot(run_jxa_fn=run_jxa_fn)
    if snapshot["status"] != "ok":
        return {}
    settings: dict[str, str] = {}
    label: Optional[str] = None
    label_depth: Optional[int] = None
    for row in snapshot.get("controls", []):
        role = row.get("role", "")
        name = row.get("name", "")
        value = row.get("value", "")
        depth = row.get("depth", 0)
        if role == "AXStaticText":
            text = name or value
            if text:
                label, label_depth = text, depth
            continue
        if role not in ("AXPopUpButton", "AXCheckBox"):
            continue
        usable_label = label if label and label_depth is not None and label_depth <= depth else None
        key = usable_label or name
        if not key:
            continue
        settings[key] = value
    return settings


def normalize_state(settings: dict[str, str]) -> str:
    """`on` / `off` / `overload_protection_only` / `unknown` for the dialog's Normalize row.

    `unknown` is returned when no row is identified as Normalize or its value cannot be classified.
    It is NOT collapsed into `on`: this function reports a reading, and the caller decides what an
    unclassified reading means. The helper refuses on `on` and proceeds on `off` or
    `overload_protection_only`, reporting `unknown` so the reading stays visible.
    """
    for row_label, value in settings.items():
        folded = row_label.lower()
        if not any(marker in folded for marker in NORMALIZE_LABEL_MARKERS):
            continue
        raw = value.strip().lower()
        if any(marker in raw for marker in OVERLOAD_MARKERS):
            return "overload_protection_only"
        if raw in OFF_VALUES:
            return "off"
        if raw in ON_VALUES:
            return "on"
        return "unknown"
    return "unknown"


def cancel_bounce_settings(
    labels: tuple[str, ...] = SAVE_PANEL_CANCEL_BUTTONS,
    run_osa: RunOsa = osa,
) -> bool:
    """Dismiss the Bounce settings dialog without rendering anything.

    A refusal that leaves Logic holding a modal sheet is not a refusal, it is a hang.
    """
    for container in ("sheet 1 of front window", "front window"):
        for label in labels:
            result = _process_body(
                f"""try
    click button "{label}" of {container}
    return "ok"
on error
    return ""
end try""",
                run_osa=run_osa,
            )
            if result == "ok":
                return True
    return False


def wait_for_bounce_dialog(run_osa: RunOsa = osa, sleep_fn: Callable[[float], None] = time.sleep) -> bool:
    for _ in range(10):
        if bounce_dialog_present(run_osa):
            return True
        sleep_fn(0.5)
    return False


def _applescript_list(values: tuple) -> str:
    """An AppleScript list literal from a label table.

    The quotes are the only thing that needs escaping: these are Logic's own labels, generated from
    AXLocalePolicy, and none of them contains a backslash. A label that did would need more than
    this, and `check-shipped-python-has-no-ui-literals.py` is what would put it here.
    """
    return "{" + ", ".join('"' + v.replace('"', '\\"') + '"' for v in values) + "}"


def open_bounce_dialog_via_menu(run_osa: RunOsa = osa) -> bool:
    # The two English-and-Korean fallback chains this used to carry are one loop over three
    # generated tables. It clicked `메뉴 바 항목 "파일"` and fell back to `"File"`, so the menu was
    # reachable in two languages and the other eight got the `on error` path twice and gave up.
    script = (
        "set frontmost to true\n"
        f"repeat with barName in {_applescript_list(FILE_MENU_BAR_ITEM)}\n"
        f"    repeat with bounceName in {_applescript_list(BOUNCE_DIALOG_KEYWORDS)}\n"
        f"        repeat with targetName in {_applescript_list(BOUNCE_PROJECT_OR_SECTION)}\n"
        "            try\n"
        "                click menu item (targetName as text) of menu 1 of menu item "
        "(bounceName as text) of menu 1 of menu bar item (barName as text) of menu bar 1\n"
        "                return \"ok\"\n"
        "            end try\n"
        "        end repeat\n"
        "    end repeat\n"
        "end repeat\n"
        "return \"\""
    )
    result = _process_body(
        script,
        run_osa=run_osa,
    )
    return result == "ok"


def bounce_focus_diagnostics(
    run_osa: RunOsa = osa,
    run_jxa_fn: RunJxa = run_jxa,
) -> BounceFocusDiagnostics:
    logic_window_names = _process_body(
        """try
    set AppleScript's text item delimiters to linefeed
    return name of windows as text
on error
    return ""
end try""",
        run_osa=run_osa,
    )
    frontmost_app = run_osa(
        '''
        tell application "System Events"
            try
                return name of first application process whose frontmost is true
            on error
                return ""
            end try
        end tell
        ''',
        OSA_TIMEOUT_SEC,
    ).strip()
    return {
        "frontmost_app": frontmost_app or None,
        "logic_front_window": logic_front_window_name(run_osa) or None,
        "logic_front_sheet": logic_front_sheet_name(run_osa) or None,
        "logic_window_names": [name for name in logic_window_names.splitlines() if name.strip()],
        "save_panel_snapshot": save_panel_snapshot(run_jxa_fn=run_jxa_fn),
    }


def open_bounce_dialog(
    run_osa: RunOsa = osa,
    sleep_fn: Callable[[float], None] = time.sleep,
    *,
    activate_fn: Callable[[], bool] = activate_logic,
) -> tuple[bool, list[str]]:
    strategies = ["key_command"]
    activate_fn()
    sleep_fn(0.8)
    _process_body("key code 11 using {command down}", run_osa=run_osa, action=True)
    if wait_for_bounce_dialog(run_osa=run_osa, sleep_fn=sleep_fn):
        return True, strategies
    strategies.append("file_menu")
    if open_bounce_dialog_via_menu(run_osa) and wait_for_bounce_dialog(run_osa=run_osa, sleep_fn=sleep_fn):
        return True, strategies
    return False, strategies


def click_bounce_settings_confirm(
    labels: tuple[str, ...] = BOUNCE_CONFIRM_BUTTONS,
    run_osa: RunOsa = osa,
    run_jxa_fn: RunJxa = run_jxa,
) -> bool:
    if not bounce_settings_present(run_jxa_fn=run_jxa_fn):
        return False
    for container in ("sheet 1 of front window", "front window"):
        for label in labels:
            if not bounce_settings_present(run_jxa_fn=run_jxa_fn):
                return False
            result = _process_body(
                f"""try
    click button "{label}" of {container}
    return "ok"
on error
    return ""
end try""",
                run_osa=run_osa,
            )
            if result == "ok":
                return True
    return False
