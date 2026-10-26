#!/usr/bin/env python3
"""Drive Logic Pro 12.2's Bounce dialog to produce an audio file at a target path.

Logic exposes no AppleScript bounce verb and its save panel's filename field is not
Accessibility-exposed, so this drives the dialog with native CGEvent posts. Coordinates
are computed from the save-panel window frame (AX-readable). The legacy sidebar click
can select different Favorites on different hosts. Recover only this run's uniquely
named fresh artifact from a bounded set of known folders, then move it to output_dir;
finding the artifact does not verify the sidebar selection itself.

CRITICAL: the input source MUST be ABC before typing or a Korean IME mangles the name.

Usage:
  logic_bounce.py --target-path PATH [--staging ~/Downloads]
  logic_bounce.py --name NAME --output-dir DIR [--staging ~/Downloads]
Prints a one-line JSON result.
"""
import argparse
import glob
import json
import os
import shutil
import sys
import time
import uuid
from typing import Optional

from logic_input_source import TARGET_INPUT_SOURCE_IDS, TISRuntime, select_input_source, set_input_abc
from logic_variants import logic_process_osa
from logic_bounce_ui import (
    OSA_TIMEOUT_SEC,
    bounce_dialog_present,
    bounce_focus_diagnostics,
    bounce_project_identity,
    bounce_settings_present,
    bounce_settings_readback,
    cancel_bounce_settings,
    click_bounce_settings_confirm,
    normalize_state,
    open_bounce_dialog,
    osa,
    save_panel_present,
    send_ui_events,
)

_select_input_source = select_input_source
# Leave time to report a truthful result before the executor's 300-second timeout.
BOUNCE_HELPER_BUDGET_SECONDS = 280.0
# Match the executor's eligible audio suffixes, never Logic's in-flight .tmp.
BOUNCE_AUDIO_SUFFIXES = {".wav", ".wave", ".aif", ".aiff", ".aifc", ".m4a", ".mp3"}


def unique_staging_name(name: str) -> str:
    return f"{name}--lpmcp-{uuid.uuid4().hex[:8]}"


def fresh_staged_file(path: str, staging_dir: str, min_mtime: float) -> bool:
    try:
        staged_dir = os.path.abspath(staging_dir)
        path_dir = os.path.abspath(os.path.dirname(path))
        path_mtime = os.path.getmtime(path)
    except OSError:
        return False
    if path_dir != staged_dir or os.path.islink(path) or not os.path.isfile(path):
        return False
    return path_mtime >= min_mtime


def find_staged_artifact(staging_dir: str, staged_name: str, min_mtime: float) -> Optional[str]:
    scored = []
    for path in glob.glob(os.path.join(glob.escape(staging_dir), f"{glob.escape(staged_name)}.*")):
        if os.path.splitext(path)[1].lower() not in BOUNCE_AUDIO_SUFFIXES:
            continue
        if not fresh_staged_file(path, staging_dir, min_mtime):
            continue
        try:
            if os.path.getsize(path) == 0:
                continue
            scored.append((os.path.getmtime(path), path))
        except OSError:
            # Candidate vanished/renamed in the race window between the filter and
            # this stat. Skip it instead of letting getmtime raise out of sorted()
            # and print a Python traceback where the Swift caller expects one-line
            # JSON (which would surface as a generic parse failure).
            continue
    scored.sort(reverse=True)
    return scored[0][1] if scored else None


def bounce_artifact_locations(staging_dir: str, output_dir: str) -> list[str]:
    home_dir = os.path.expanduser("~")
    candidates = [staging_dir]
    candidates.extend(os.path.expanduser(path) for path in (
        "~/Documents", "~/Desktop", "~/Music", "~/Movies", "~/Downloads",
    ))
    candidates.extend([home_dir, output_dir])
    locations = []
    for candidate in candidates:
        canonical = os.path.realpath(os.path.abspath(candidate))
        if canonical not in locations:
            locations.append(canonical)
    return locations


def move_staged_artifact_no_overwrite(staged_path: str, final_path: str) -> Optional[str]:
    try:
        source = open(staged_path, "rb")
    except OSError as exc:
        return f"artifact_stage_unreadable: {exc}"

    output_dir = os.path.dirname(final_path)
    final_name = os.path.basename(final_path)
    dir_flags = os.O_RDONLY
    if hasattr(os, "O_DIRECTORY"):
        dir_flags |= os.O_DIRECTORY
    if hasattr(os, "O_NOFOLLOW"):
        dir_flags |= os.O_NOFOLLOW

    try:
        dir_fd = os.open(output_dir, dir_flags)
    except OSError:
        source.close()
        return "artifact_output_dir_unsafe"

    create_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        create_flags |= os.O_NOFOLLOW

    try:
        fd = os.open(final_name, create_flags, 0o644, dir_fd=dir_fd)
    except FileExistsError:
        os.close(dir_fd)
        source.close()
        return "artifact_already_exists"
    except OSError as exc:
        os.close(dir_fd)
        source.close()
        return f"artifact_move_failed: {exc}"

    try:
        with source, os.fdopen(fd, "wb") as destination:
            shutil.copyfileobj(source, destination)
        os.unlink(staged_path)
    except OSError as exc:
        try:
            os.unlink(final_name, dir_fd=dir_fd)
        except OSError:
            pass
        return f"artifact_move_failed: {exc}"
    finally:
        os.close(dir_fd)
    return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--target-path", help="planned destination path (extension may be replaced with the actual bounce format)")
    ap.add_argument("--name", help="legacy filename without extension")
    ap.add_argument("--output-dir", help="legacy final destination dir (absolute)")
    ap.add_argument("--staging", default=os.path.expanduser("~/Downloads"))
    args = ap.parse_args()

    if args.target_path:
        target_path = os.path.abspath(args.target_path)
        output_dir = os.path.dirname(target_path)
        target_stem_path, _ = os.path.splitext(target_path)
        target_name = os.path.basename(target_stem_path)
    elif args.name and args.output_dir:
        output_dir = os.path.abspath(args.output_dir)
        target_name = args.name
        target_stem_path = os.path.join(output_dir, target_name)
        target_path = target_stem_path
    else:
        ap.error("provide --target-path or the legacy --name + --output-dir pair")

    result = {"name": target_name, "output_dir": output_dir, "target_path": target_path}
    result["bounce_fired"] = False
    helper_deadline = time.monotonic() + BOUNCE_HELPER_BUDGET_SECONDS
    project_identity = bounce_project_identity()
    if project_identity is None:
        result["success"] = False
        result["error"] = "bounce_project_window_unavailable"
        print(json.dumps(result)); return 1

    # 1. deterministic input-source switch (avoid Korean IME mangling the filename)
    if not set_input_abc():
        result["success"] = False
        result["error"] = "input_source_switch_failed"
        print(json.dumps(result)); return 1
    time.sleep(0.4)

    dialog_up, dialog_open_strategies = open_bounce_dialog()
    result["dialog_open_strategies"] = dialog_open_strategies
    if not dialog_up:
        result["success"] = False
        result["error"] = "bounce_dialog_did_not_appear"
        result.update(bounce_focus_diagnostics())
        print(json.dumps(result)); return 1

    # 2b. Read the settings the dialog is about to apply, BEFORE pressing anything.
    #
    # `bounce_settings_present` proves the dialog is here by finding marker strings; it cannot say
    # which control holds which value. A bounce whose Normalize state was never read is an
    # unverified deliverable however well the audio analyzes, so the values travel back in the
    # helper's JSON and the one state that silently changes the render's level is refused.
    settings = bounce_settings_readback()
    if settings:
        result["bounce_settings"] = settings
        normalize = normalize_state(settings)
        result["bounce_normalize"] = normalize
        if normalize == "on":
            cancel_bounce_settings()
            result["success"] = False
            result["error"] = "bounce_normalize_enabled"
            result["bounce_fired"] = False
            print(json.dumps(result)); return 1
    else:
        # Not a refusal by itself: the dialog may expose no individually readable controls. The
        # absence is reported so a caller never reads it as "settings were off".
        result["bounce_normalize"] = "unknown"

    # 3. OK on the (AX-accessible) settings dialog -> save panel
    if not click_bounce_settings_confirm():
        result["success"] = False
        result["error"] = "bounce_confirm_button_not_found"
        print(json.dumps(result)); return 1
    time.sleep(2.5)
    result["save_panel_present"] = save_panel_present()
    if not result["save_panel_present"]:
        result["success"] = False
        result["error"] = "bounce_save_panel_did_not_appear"
        result.update(bounce_focus_diagnostics())
        print(json.dumps(result)); return 1

    # 4. read the save-panel window frame
    pos = logic_process_osa("get position of front window", timeout_sec=OSA_TIMEOUT_SEC)
    size = logic_process_osa("get size of front window", timeout_sec=OSA_TIMEOUT_SEC)
    try:
        ox, oy = [int(v.strip()) for v in pos.split(",")]
        w, h = [int(v.strip()) for v in size.split(",")]
    except (TypeError, ValueError):
        result["success"] = False
        result["error"] = f"could_not_read_save_panel_frame pos={pos!r} size={size!r}"
        print(json.dumps(result)); return 1
    result["panel_frame"] = [ox, oy, w, h]

    staged_name = unique_staging_name(target_name)

    # 5. set a clean Save As name (offsets calibrated live against the standard
    # Logic 12.2 bounce save panel: frame [520,142,880,604] -> field (1040,196))
    saveas = (ox + int(0.591 * w), oy + 54)
    if not send_ui_events(f"c:{saveas[0]},{saveas[1]}"):
        result["success"] = False
        result["error"] = "save_panel_name_click_failed"
        print(json.dumps(result)); return 1
    time.sleep(0.4)
    if not send_ui_events("kd:cmd", "t:a", "ku:cmd"):
        result["success"] = False
        result["error"] = "save_panel_name_select_failed"
        print(json.dumps(result)); return 1
    time.sleep(0.2)
    if not send_ui_events("kp:delete"):
        result["success"] = False
        result["error"] = "save_panel_name_clear_failed"
        print(json.dumps(result)); return 1
    time.sleep(0.2)
    if not send_ui_events(f"t:{staged_name}"):
        result["success"] = False
        result["error"] = "save_panel_name_type_failed"
        print(json.dumps(result)); return 1
    time.sleep(0.4)

    # 6. Legacy staging-Favorite click. Its row varies by host, so this click
    # does not establish the destination; recovery below observes the actual file.
    downloads = (ox + 86, oy + 184)
    if not send_ui_events(f"c:{downloads[0]},{downloads[1]}"):
        result["success"] = False
        result["error"] = "save_panel_staging_sidebar_click_failed"
        print(json.dumps(result)); return 1
    time.sleep(1.0)

    # 7. clear any prior staged artifact, then click the Bounce default button
    # (bottom-right corner of the panel: frame +(w-60, h-32) -> (1340,714)).
    staged = os.path.join(args.staging, f"{staged_name}.aif")
    if os.path.exists(staged):
        os.remove(staged)
    bounce_btn = (ox + w - 60, oy + h - 32)
    if time.monotonic() >= helper_deadline:
        result["success"] = False
        result["error"] = "bounce_helper_deadline_exhausted_before_write"
        print(json.dumps(result)); return 1
    bounce_started_at = time.time()
    if not send_ui_events(f"c:{bounce_btn[0]},{bounce_btn[1]}"):
        result["success"] = False
        result["error"] = "bounce_button_click_failed"
        print(json.dumps(result)); return 1
    result["bounce_fired"] = True

    # 8. Find only this run's exact fresh name, non-recursively, in the known
    # staging/user/output locations. Never select between conflicting locations.
    # The single monotonic budget includes dialog setup, unlike a second full
    # 300-second poll that the parent would kill before it could report.
    appeared = None
    pending_artifact = None
    locations = bounce_artifact_locations(args.staging, output_dir)
    while time.monotonic() < helper_deadline:
        # A final suffix can already exist while Logic is still rendering it.
        # Require the original saved project to return, then an unchanged file
        # across two polls. Failed UI observations never mean completion.
        observed_project = bounce_project_identity()
        candidates = [path for directory in locations
                      if (path := find_staged_artifact(directory, staged_name, bounce_started_at)) is not None]
        if len(candidates) > 1:
            result["success"] = False
            result["error"] = "ambiguous_bounce_artifacts"
            print(json.dumps(result)); return 1
        signature = None
        if candidates and observed_project == project_identity:
            try:
                info = os.stat(candidates[0], follow_symlinks=False)
                signature = (candidates[0], info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns)
            except OSError:
                pass
        if signature is not None and signature == pending_artifact:
            appeared = candidates[0]
            break
        pending_artifact = signature
        time.sleep(1.0)
    if not appeared:
        result["success"] = False
        result["error"] = "artifact_not_found_within_helper_budget"
        print(json.dumps(result)); return 1
    result["staging_directory"] = os.path.dirname(appeared)

    # 9. move to the requested output_dir (locate-and-move)
    if os.path.lexists(output_dir):
        if os.path.islink(output_dir) or not os.path.isdir(output_dir):
            result["success"] = False
            result["error"] = "artifact_output_dir_unsafe"
            print(json.dumps(result)); return 1
    else:
        try:
            os.makedirs(output_dir, exist_ok=False)
        except OSError as exc:
            result["success"] = False
            result["error"] = f"artifact_move_failed: {exc}"
            print(json.dumps(result)); return 1
    _, ext = os.path.splitext(appeared)
    final = f"{target_stem_path}{ext}"
    move_error = move_staged_artifact_no_overwrite(appeared, final)
    if move_error:
        result["success"] = False
        result["error"] = move_error
        result["artifact"] = final
        print(json.dumps(result)); return 1
    result["success"] = True
    result["artifact"] = final
    result["size_bytes"] = os.path.getsize(final)
    print(json.dumps(result)); return 0


if __name__ == "__main__":
    sys.exit(main())
