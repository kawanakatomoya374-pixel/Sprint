# A small "workbench" window: menu bar, a resizable split between a tree and a sortable table,
# a spinner and radio group, a context menu, tooltips and toasts. Driven by scripted events,
# so the output (and the screenshot) is identical on every run.
import gui

let log = []
let files = [
    ["main.sp", 1280, "source"],
    ["gui.sp", 52210, "library"],
    ["README", 4096, "doc"],
    ["bench.sp", 880, "source"],
    ["notes", 310, "doc"],
    ["spec.md", 91000, "doc"]
]
let kind_nodes = [gui.node("all", [gui.node("source"), gui.node("library"), gui.node("doc")])]
kind_nodes[0].open = true
let table = gui.table([["name", 80], ["bytes", 56], "kind"], files, 200, 110)
let tree = gui.tree(kind_nodes, 110, 110, t => app_filter(t.selected.label))
func app_filter(kind):
    let rows = files if kind == "all" else files.filter(r => r[2] == kind)
    table.set_rows(rows)

let size = gui.spinner(12, 8, 32, 2)
let mode = gui.radio(["list", "grid"], 0)
let side = gui.column([gui.label("Size"), size, gui.label("View"), mode], 4, 6)
let split = gui.splitter(gui.row([tree, side], 6, 6), table, false, 190)
let bar = gui.menubar([
    ["File", [["Refresh", a => a.toast("refreshed")], "-", ["Quit", a => a.quit()]]],
    ["View", [["Sort by size", a => table.sort_by(1, true)], ["Reset", a => table.sort_by(-1)]]]
])
let app = gui.App(420, 170, "workbench")
app.fill(gui.column([bar, split], 0, 0))
split.flex = 1
table.tip = "click a header to sort"
table.context = [["Sort by name", a => table.sort_by(0)], ["Sort by size", a => table.sort_by(1, true)]]
app.relayout()

app.click(tree.abs_x() + 30, tree.abs_y() + 2 + 12 * 3 + 5)
log.append(table.rows.map(r => r[0]).join(","))
app.click(table.abs_x() + 70, table.abs_y() + 5)
log.append(table.order.map(to_string).join(","))
app.right_click(table.abs_x() + 20, table.abs_y() + 40)
app.press("Down")
app.press("Down")
app.press("Enter")
log.append(table.order.map(to_string).join(","))
app.click(bar.abs_x() + 6, bar.abs_y() + 6)
app.click(bar.abs_x() + 10, bar.abs_y() + 16 + 5)
app.hover_at(table.abs_x() + 30, table.abs_y() + 40)
app.advance(600)
app.screenshot("build/gui_workbench.png")
print(log.join(" | "))
print(len(app.toasts), app.snapshot() > 0)
