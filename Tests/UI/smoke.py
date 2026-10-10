#!/usr/bin/env python3
"""End-to-end UI smoke test: drives the real app with input events (scripts/ui.swift) and checks its
state through the debug bridge. Works only inside build/testdata, never touches other files."""
import json, os, subprocess, sys, time, shutil

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
B = os.path.join(ROOT, "build")
TD = os.path.join(B, "testdata")
failures = []

def ui(s): subprocess.run([os.path.join(B, "ui"), s]); time.sleep(0.35)
def dbg(*a): subprocess.run([os.path.join(B, "dbg"), *a]); time.sleep(0.25)
def state():
    p = os.path.join(B, "state.json")
    if os.path.exists(p): os.remove(p)
    dbg("state", p)
    for _ in range(20):
        if os.path.exists(p):
            try: return json.load(open(p))
            except Exception: pass
        time.sleep(0.1)
    return {}
def check(name, cond, info=""):
    print(("PASS " if cond else "FAIL ") + name + ("" if cond else f"  -> {info}"))
    if not cond: failures.append(name)
def snap(name): dbg("snapshot", os.path.join(B, "ui-" + name + ".png"))

def reset_testdata():
    shutil.rmtree(TD, ignore_errors=True)
    os.makedirs(os.path.join(TD, "alpha", "inner")); os.makedirs(os.path.join(TD, "beta")); os.makedirs(os.path.join(TD, "gamma folder"))
    open(os.path.join(TD, "notes.txt"), "w").write("hello\n")
    open(os.path.join(TD, "readme.md"), "w").write("# t\n")
    open(os.path.join(TD, "big.bin"), "w").write("x" * 5000)
    open(os.path.join(TD, ".hidden_thing"), "w").close()

reset_testdata()
# Only the instance this test starts is ever stopped: never the Porpoise you use, nor its helper.
subprocess.run(["defaults", "delete", "app.porpoise.uitest"], capture_output=True)
shutil.rmtree("/private/tmp/porpoise-test", ignore_errors=True)
env = dict(os.environ, PORPOISE_DEFAULTS_SUITE="app.porpoise.uitest", PORPOISE_DEBUG="1")
APP = subprocess.Popen([os.path.join(B, "Porpoise.app/Contents/MacOS/Porpoise"), TD], env=env, stdout=open(os.path.join(B, "app.log"), "w"), stderr=subprocess.STDOUT)
time.sleep(2.5)
ui("focus")
s = state()
check("opens folder from argument", s.get("url") == TD, s.get("url"))
check("hidden files hidden", ".hidden_thing" not in s.get("rows", []), s.get("rows"))
check("folders first natural order", s.get("rows", [])[:3] == ["alpha", "beta", "gamma folder"], s.get("rows"))
check("status text", s.get("status", "").startswith("3 folders, 3 files"), s.get("status"))

# View modes
for k, m in [("cmd+3", "details"), ("cmd+2", "compact"), ("cmd+1", "icons")]:
    ui(f"click 600 500; key {k}"); check("view mode " + m, state().get("mode") == m)

# Hidden files toggle
ui("key cmd+h"); s = state(); check("Cmd+H shows hidden", ".hidden_thing" in s["rows"], s["rows"])
ui("key cmd+h"); check("Cmd+H hides again", ".hidden_thing" not in state()["rows"])

# Type-ahead + Return opens folder, Backspace goes back, Alt+Up goes up
ui("type be; key return"); s = state(); check("type-ahead + Return opens beta", s["url"].endswith("/beta"), s["url"])
ui("key backspace"); s = state(); check("Backspace = Back", s["url"] == TD, s["url"])
check("came-from folder selected after back", s["selection"] == ["beta"] or s["current"] == "beta", s)
ui("key opt+right"); check("Opt+Right = Forward", state()["url"].endswith("/beta"))
ui("key opt+up"); s = state(); check("Opt+Up = Up", s["url"] == TD and s["current"] == "beta", s)

# Zoom
z0 = state()["zoom"]; ui("key cmd+="); check("Cmd+= zooms in", state()["zoom"] == z0 + 1)
ui("key cmd+0"); check("Cmd+0 resets zoom", state()["zoom"] == z0)

# Filter bar
ui("key cmd+i; wait 0.3; type note"); s = state()
check("filter bar visible", s["filterVisible"]); check("filter applies", s["rows"] == ["notes.txt"], s["rows"])
ui("esc; esc"); s = state(); check("Esc closes filter", not s["filterVisible"] and len(s["rows"]) == 6, s)

# Create folder via Cmd+Shift+N (dialog), type name, Return
ui("key cmd+shift+n; wait 0.6; key cmd+a; type made by test; key return; wait 0.8")
s = state(); check("Create Folder", "made by test" in s["rows"], s["rows"])
check("new folder selected", s["selection"] == ["made by test"], s["selection"])

# Inline rename with F2
ui("key f2; wait 0.3; key cmd+a; type renamed dir; key return; wait 0.8")
s = state(); check("F2 inline rename", "renamed dir" in s["rows"] and "made by test" not in s["rows"], s["rows"])
ui("key cmd+z; wait 0.8"); s = state(); check("Cmd+Z undoes rename", "made by test" in s["rows"], s["rows"])

# Copy / paste in same folder = "copy" name; trash with Cmd+Backspace; undo trash
dbg("select", os.path.join(TD, "notes.txt"))
ui("key cmd+c; key cmd+v; wait 1.0"); s = state(); check("Paste in same folder makes copy", "notes copy.txt" in s["rows"], s["rows"])
dbg("select", os.path.join(TD, "notes copy.txt"))
ui("key cmd+backspace; wait 1.0"); s = state(); check("Cmd+Backspace moves to Trash", "notes copy.txt" not in s["rows"], s["rows"])
ui("key cmd+z; wait 1.0"); s = state(); check("Undo trash restores", "notes copy.txt" in s["rows"], s["rows"])

# Duplicate (Cmd+D) then Esc to cancel the inline rename
dbg("select", os.path.join(TD, "readme.md"))
ui("key cmd+d; wait 1.2; esc"); s = state(); check("Duplicate Here", "readme copy.md" in s["rows"], s["rows"])

# Split view
ui("click 600 500; key f3; wait 0.6"); s = state(); check("F3 splits", s["split"] and s["activeIsSecondary"], s)
ui("key ctrl+tab"); ui("key cmd+f3"); s = state(); check("Focus other view", s["split"] and not s["activeIsSecondary"], s)
snap("split")
ui("key f3; wait 0.4"); check("F3 closes split", not state()["split"])

# Tabs
ui("key cmd+t; wait 0.5"); s = state(); check("Cmd+T new tab", len(s["tabs"]) == 2 and s["currentTab"] == 1, s["tabs"])
ui("key ctrl+tab"); check("Ctrl+Tab next tab", state()["currentTab"] == 0)
ui("key cmd+w; wait 0.4"); s = state(); check("Cmd+W closes tab", len(s["tabs"]) == 1, s["tabs"])
ui("key cmd+shift+t; wait 0.5"); s = state(); check("Undo close tab", len(s["tabs"]) == 2, s["tabs"])
ui("key cmd+w; wait 0.3")
dbg("navigate", TD); time.sleep(0.5)

# Location bar
ui("key cmd+l; wait 0.3"); s = state(); check("Cmd+L edits location", s["breadcrumbEditing"], s)
ui(f"key cmd+a; type {TD}/alpha; key return; wait 0.6"); s = state()
check("typed location navigates", s["url"].endswith("/alpha") and not s["breadcrumbEditing"], s)
ui("key backspace; wait 0.4")

# Search
ui("key cmd+f; wait 0.3; type inner; wait 2.5"); s = state()
check("search finds nested folder", s["searchVisible"] and "inner" in s["rows"], s["rows"])
ui("esc; wait 0.4"); s = state(); check("Esc closes search", not s["searchVisible"] and len(s["rows"]) >= 6, s)

# Terminal panel follows the view
ui("click 600 500; key f4; wait 2.0"); s = state()
check("F4 terminal panel", s["panels"]["terminal"], s["panels"])
check("terminal starts in view folder", s["terminalCwd"] == s["url"], (s["terminalCwd"], s["url"]))
snap("terminal")
ui("click 600 300; type alp; key return; wait 1.5"); s = state()
check("terminal follows view", s["terminalCwd"].endswith("/alpha"), s["terminalCwd"])
ui("key backspace; wait 0.5; key f4; wait 0.4")

# Panels
ui("key f9"); check("F9 hides Places", not state()["panels"]["places"]); ui("key f9")
ui("key cmd+opt+i; wait 0.5"); check("Cmd+Opt+I Information panel", state()["panels"]["info"]); snap("info"); ui("key cmd+opt+i")
ui("key f7; wait 0.5"); check("F7 Folders panel", state()["panels"]["folders"]); snap("folders"); ui("key f7")

# Selection mode: clicks toggle, Esc leaves
dbg("navigate", TD); time.sleep(0.6)
ui("click 600 500; key cmd+1; key cmd+shift+space; wait 0.4")
st = state()
# Icons grid: first row items at x≈ 140+71+i*142 (window coords), y≈ 130
ui("click 211 130; click 353 130; wait 0.3"); s = state()
check("selection mode toggles items", sorted(s["selection"]) == ["alpha", "beta"], s["selection"])
ui("click 353 130; wait 0.2"); check("selection mode click deselects", state()["selection"] == ["alpha"])
ui("esc; wait 0.3; click 900 600; wait 0.2"); check("Esc leaves selection mode", state()["selection"] == [])

# Live updates: files created outside the app appear without reloading
open(os.path.join(TD, "zz_external.txt"), "w").close(); time.sleep(1.2)
check("folder watcher picks up external changes", "zz_external.txt" in state()["rows"])
os.remove(os.path.join(TD, "zz_external.txt")); time.sleep(1.2)

# Drag big.bin onto beta, choose "Move Here" from Dolphin's drop menu
rows = state()["rows"]
def pos(name):
    i = rows.index(name); col = i % 7; row = i // 7
    return 211 + col * 142, 130 + row * 106
bx, by = pos("big.bin"); tx, ty = pos("beta")
ui(f"drag {bx} {by} {tx},{ty}; wait 1.2; esc; wait 0.6")
s = state()
check("plain drop asks (Esc cancels the drop menu)", "big.bin" in s["rows"] and not os.path.exists(os.path.join(TD, "beta", "big.bin")), s["rows"])
ui(f"drag {bx} {by} {tx},{ty},cmd; wait 1.5")
s = state()
check("Cmd-drag moves without asking", "big.bin" not in s["rows"] and os.path.exists(os.path.join(TD, "beta", "big.bin")), s["rows"])

# Context menu: right-click an item, pick "Rename…" by typing, inline editor opens
dbg("navigate", TD); time.sleep(0.6)
rows = state()["rows"]
i = rows.index("notes.txt"); x, y = 211 + (i % 7) * 142, 130 + (i // 7) * 106
ui(f"rclick {x} {y}; wait 0.6; type Rena; key return; wait 0.6")
s = state(); check("context menu Rename… starts inline rename", s["renaming"] and s["selection"] == ["notes.txt"], s)
ui("esc; wait 0.3")
ui(f"rclick 900 650; wait 0.6; esc; wait 0.3"); check("background context menu opens and closes", not state()["renaming"])

# Settings window
ui("key cmd+,; wait 1.0"); s = state()
check("Cmd+, opens Settings", s["keyWindowTitle"] == "Settings", s["keyWindowTitle"])
dbg("keysnapshot", os.path.join(B, "ui-settings.png")); ui("key cmd+w; wait 0.4")
check("Cmd+W closes the Settings window", state()["keyWindowTitle"] != "Settings", state()["keyWindowTitle"])

# Toolbar: Back button, hamburger menu, View Settings dropdown (menus chosen by typing)
dbg("navigate", TD); time.sleep(0.4); dbg("navigate", os.path.join(TD, "alpha")); time.sleep(0.5)
ui("click 96 23; wait 0.6"); check("toolbar Back button", state()["url"] == TD)
w = state()["windowFrame"][2]
ui(f"click {w - 22} 23; wait 0.6; type New Tab; key return; wait 0.6"); s = state()
check("hamburger menu → New Tab", len(s["tabs"]) == 2, s["tabs"])
ui("key cmd+w; wait 0.4")
ui("click 188 23; wait 0.6; type Details; key return; wait 0.5"); check("View Settings dropdown → Details", state()["mode"] == "details")
ui("click 160 23; wait 0.4"); check("View mode button cycles", state()["mode"] == "icons")

# Breadcrumb: clicking the first crumb ("Home") navigates there; the arrow menu lists subfolders
dbg("navigate", os.path.join(TD, "alpha")); time.sleep(0.5)
ui("click 246 23; wait 0.6"); s = state()
check("breadcrumb crumb click", s["url"] == os.path.expanduser("~"), s["url"])
ui("key backspace; wait 0.5")
ui("click 1000 23; wait 0.4"); s = state(); check("click empty breadcrumb area edits", s["breadcrumbEditing"], s)
ui("esc; wait 0.3")

# ---- Round 2: things reported broken ----
dbg("navigate", TD); time.sleep(0.5)
st = state(); fx, fy, fw, fh = st["windowFrame"]
# Window drag from the empty part of the breadcrumb (it sits in the title bar)
ui("drag 1000 26 1060,66; wait 0.5"); fr = state()["windowFrame"]
check("drag breadcrumb empty area moves window", abs(fr[0] - fx - 60) < 3 and abs(fr[1] - fy + 40) < 3, (fx, fy, fr))
ui("drag 1060 26 1000,-14; wait 0.5")
# Window drag from the empty tab bar
ui("key cmd+t; wait 0.5"); st = state(); fx, fy = st["windowFrame"][0], st["windowFrame"][1]
ui("drag 900 70 960,110; wait 0.5"); fr = state()["windowFrame"]
check("drag empty tab bar moves window", 45 < fr[0] - fx < 63, (fx, fy, fr))
ui("drag 960 70 900,30; wait 0.3; key cmd+w; wait 0.4")

# Places: drag "Documents" below "Downloads" reorders entries
# Rows: toolbar 52 + header 30, then 28 pt rows: Home, Desktop, Documents (≈166), Downloads (≈194)
before = state()["places"]
ui("drag 60 152 60,200; wait 0.8"); after = state()["places"]
check("places drag reorders", after.index("Documents") == after.index("Downloads") + 1, after)
ui("drag 60 180 60,145; wait 0.8"); check("places drag back restores order", state()["places"] == before, state()["places"])

# Details columns: resize Size by dragging its right edge, reorder Modified before Size
dbg("navigate", TD); time.sleep(0.4)
ui("click 700 500; key cmd+3; wait 0.5"); st = state()
roles = st["detailsRoles"]; widths = st["columnWidths"]
x0 = 160 + 1 + 20 + widths["name"]              # sidebar (160) + divider + side padding + Name
size_edge = x0 + widths["size"]
ui(f"drag {int(size_edge)} 66 {int(size_edge) + 50},66; wait 0.5"); st = state()
check("column resize", abs(st["columnWidths"]["size"] - widths["size"] - 50) < 4, (widths["size"], st["columnWidths"]["size"]))
widths = st["columnWidths"]
mod_x = x0 + widths["size"] + widths["modificationTime"] / 2
ui(f"drag {int(mod_x)} 66 {int(x0 + 10)},66; wait 0.6"); st = state()
check("column reorder (Modified before Size)", st["detailsRoles"][:3] == ["name", "modificationTime", "size"], st["detailsRoles"])
ui("key cmd+1; wait 0.4")

# Zoom: slider pill drag is continuous; Cmd+= animates to the next step
s0 = state()["iconSize"]; w = state()["windowFrame"][2]; h = state()["windowFrame"][3]
ui(f"drag {int(w - 12 - 168 + 28 + 40)} {int(h - 10 - 14)} {int(w - 12 - 168 + 28 + 70)},{int(h - 10 - 14)}; wait 1.0")
s1 = state()["iconSize"]
check("zoom slider changes size continuously", s1 > s0 and s1 not in (16, 22, 32, 48, 64, 80, 96), (s0, s1))
ui("key cmd+0; wait 0.6"); ui("key cmd+=; wait 0.6"); check("Cmd+= steps to the next size", state()["iconSize"] == 80, state()["iconSize"])
ui("key cmd+0; wait 0.6")

# Terminal: follows the view quickly; `exit` closes the panel
dbg("navigate", TD); time.sleep(0.4)
ui("click 700 500; key f4; wait 3.0")
dbg("navigate", os.path.join(TD, "alpha")); time.sleep(0.7)
check("terminal follows within 0.7 s", state()["terminalCwd"].endswith("/alpha"), state()["terminalCwd"])
ui("key ctrl+shift+f4; wait 0.4") if False else None
ui("click 600 700; wait 0.3; type exit; key return; wait 1.5")
check("typing exit closes the terminal panel", not state()["panels"]["terminal"], state()["panels"])
ui("click 700 400; key f4; wait 2.5"); check("F4 after exit starts a fresh terminal", state()["terminalCwd"] != "", state()["terminalCwd"])
ui("key f4; wait 0.5")

# Trash opens (contents if Full Disk Access is granted, otherwise an explanation with a settings button)
dbg("navigate", os.path.expanduser("~/.Trash")); time.sleep(1.0); st = state()
check("Trash opens or explains the macOS permission", st["url"].endswith("/.Trash") and (len(st["rows"]) > 0 or "Full Disk Access" in st["message"]), (st["rows"][:3], st["message"]))

snap("final")
APP.terminate()
print(f"\n{len(failures)} failure(s)" + (": " + ", ".join(failures) if failures else ""))
sys.exit(1 if failures else 0)
