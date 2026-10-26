#!/usr/bin/env python3
"""Shared System Events JXA helpers for Logic Pro UI guard scripts."""

from __future__ import annotations

import json
import subprocess
from typing import Final, List, Tuple, Union

from logic_variants import jxa_find_process_snippet


JsonValue = Union[str, int, float, bool, None, List["JsonValue"], dict[str, "JsonValue"]]


def bounce_project_snapshot_source() -> str:
    find_process = jxa_find_process_snippet(se_binding="se", proc_var="proc")
    return "\n".join([
        'const se = Application("System Events");',
        find_process,
        'try {',
        '  if (proc === null) throw new Error("logic_not_running");',
        '  const windows = proc.windows();',
        '  if (windows.length === 0) throw new Error("missing_front_window");',
        '  const win = windows[0];',
        '  JSON.stringify({status: "ok", process_id: proc.unixId(),',
        '    role: win.role(), subrole: win.subrole(),',
        '    document: win.attributes.byName("AXDocument").value(),',
        '    sheet_count: win.sheets().length});',
        '} catch (error) {',
        '  JSON.stringify({status: "error", reason: String(error)});',
        '}',
    ])


def save_panel_snapshot_source() -> str:
    find_process = jxa_find_process_snippet(se_binding="se", proc_var="proc")
    return "\n".join([
        "function safe(fn, fallback) {",
        "  try {",
        "    return fn();",
        "  } catch (error) {",
        "    return fallback;",
        "  }",
        "}",
        "",
        "function str(value) {",
        "  return value === undefined || value === null ? \"\" : String(value);",
        "}",
        "",
        "function walk(node, bucket, depth) {",
        "  if (depth > 6) return;",
        "  const role = str(safe(() => node.role(), \"\"));",
        "  const name = str(safe(() => node.name(), \"\"));",
        "  const value = str(safe(() => node.value(), \"\"));",
        "  if (role === \"AXButton\" && name) bucket.button_names.push(name);",
        "  if (role === \"AXTextField\") {",
        "    if (name) bucket.text_field_names.push(name);",
        "    bucket.text_field_count += 1;",
        "  }",
        "  if (role === \"AXStaticText\" && (name || value)) {",
        "    bucket.static_texts.push(name || value);",
        "  }",
        "  // Document-ordered rows, so a caller can pair a control with the label drawn before it.",
        "  // `name` and `value` are both kept: Logic puts a slider's title in AXDescription and its",
        "  // reading in AXValue, and a popup's reading in one or the other depending on the control.",
        "  if (role === \"AXStaticText\" || role === \"AXPopUpButton\" || role === \"AXCheckBox\") {",
        "    bucket.controls.push({role: role, name: name, value: value, depth: depth});",
        "  }",
        "  const children = safe(() => node.uiElements(), []);",
        "  for (let index = 0; index < children.length; index += 1) {",
        "    walk(children[index], bucket, depth + 1);",
        "  }",
        "}",
        "",
        "const se = Application(\"System Events\");",
        find_process,
        "if (proc === null) {",
        "  JSON.stringify({status: \"logic_not_running\"});",
        "} else {",
        "  const win = safe(() => proc.windows[0], null);",
        "  if (!win) {",
        "    JSON.stringify({status: \"missing_front_window\"});",
        "  } else {",
        "    const bucket = {",
        "      status: \"ok\",",
        "      button_names: [],",
        "      text_field_names: [],",
        "      text_field_count: 0,",
        "      static_texts: [],",
        "      controls: [],",
        "    };",
        "    walk(win, bucket, 0);",
        "    JSON.stringify(bucket);",
        "  }",
        "}",
    ])


def run_jxa(
    source: str,
    *,
    timeout: float = 12.0,
    run=subprocess.run,
) -> subprocess.CompletedProcess[str]:
    return run(
        ["/usr/bin/osascript", "-l", "JavaScript"],
        input=source,
        text=True,
        capture_output=True,
        check=False,
        timeout=timeout,
    )


def parse_jxa_json_result(result: subprocess.CompletedProcess[str]) -> dict[str, JsonValue]:
    try:
        parsed = json.loads(result.stdout.strip() or "{}")
    except json.JSONDecodeError:
        return {
            "status": "error",
            "reason": "invalid_jxa_output",
            "stderr": (result.stderr or "").strip(),
            "stdout": (result.stdout or "").strip(),
        }
    return parsed if isinstance(parsed, dict) else {"status": "error", "reason": "invalid_jxa_output"}


def ui_prelude(
    *,
    marker_constant: str,
    markers: Union[List[str], Tuple[str, ...]],
    include_menu_items: bool = False,
) -> str:
    markers_json = json.dumps(list(markers), ensure_ascii=False)
    menu_item_case = (
        '  if (roleName === "menu item") return safe(() => container.menuItems(), []);\n'
        if include_menu_items
        else ""
    )
    return f"""
const {marker_constant} = {markers_json};

function safe(fn, fallback) {{
  try {{
    return fn();
  }} catch (error) {{
    return fallback;
  }}
}}

function str(value) {{
  return value === undefined || value === null ? "" : String(value);
}}

function safeName(item) {{
  const name = safe(() => item.name(), "");
  if (name) return str(name);
  const description = safe(() => item.description(), "");
  if (description) return str(description);
  return str(safe(() => item.value(), ""));
}}

function namesOf(collection) {{
  const output = [];
  for (let index = 0; index < collection.length; index += 1) {{
    const name = safeName(collection[index]);
    if (name) output.push(name);
  }}
  return output;
}}

function namedStates(collection) {{
  const output = [];
  for (let index = 0; index < collection.length; index += 1) {{
    const item = collection[index];
    const name = safeName(item) || "<unnamed>";
    output.push({{ name, value: str(safe(() => item.value(), "")) }});
  }}
  return output;
}}

function containsMarker(values) {{
  return values.some((value) => {marker_constant}.some((marker) => str(value).includes(marker)));
}}

function collection(container, roleName) {{
  if (roleName === "button") return safe(() => container.buttons(), []);
  if (roleName === "checkbox") return safe(() => container.checkboxes(), []);
  if (roleName === "radio button") return safe(() => container.radioButtons(), []);
  if (roleName === "static text") return safe(() => container.staticTexts(), []);
{menu_item_case}  return [];
}}
"""
