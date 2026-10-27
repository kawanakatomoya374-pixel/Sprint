import gui

let log = []
let bar = gui.menubar([
    ["File", [["Open", a => log.append("open")], "-", ["Quit", a => log.append("quit")]]],
    ["Edit", [["Copy", a => log.append("copy")], ["Paste", a => log.append("paste")]]]
])
let nodes = [
    gui.node("src", [gui.node("main.sp"), gui.node("lib", [gui.node("a.sp"), gui.node("b.sp")])]),
    gui.node("docs", [gui.node("README")]),
    gui.node("LICENSE")
]
let picked = []
let tr = gui.tree(nodes, 120, 60, w => picked.append(w.selected.label))
let ui = gui.column([bar, tr], 4, 0)
let app = gui.App(200, 140)
app.fill(ui)
print(bar.h, bar.header_x(1), bar.list_w(0), bar.list_h(0))

# open File with a click, then pick Quit (after the separator)
let hx = bar.abs_x() + 6
let hy = bar.abs_y() + 6
app.click(hx, hy)
print(bar.open_at, app.popup == bar)
let lx = bar.abs_x() + bar.header_x(0) - 4
let ly = bar.abs_y() + bar.h
app.click(lx + 10, ly + bar.row_y(0, 2) + 5)
print(log, bar.open_at, app.popup == nil)
# a separator keeps the list open; clicking elsewhere closes it
app.click(hx, hy)
app.click(lx + 10, ly + bar.row_y(0, 1) + 2)
print(log, bar.open_at)
app.click(150, 120)
print(bar.open_at, app.popup == nil)
# switching headers, keyboard
app.click(hx, hy)
app.click(bar.abs_x() + bar.header_x(1) + 3, hy)
print(bar.open_at)
app.press("Down")
app.press("Down")
app.press("Enter")
print(log, bar.open_at)
app.set_focus(bar)
app.press("Down")
print(bar.open_at)
app.press("Right")
app.press("Left")
app.press("Down")
app.press("Up")
print(bar.open_at, bar.sel)
app.press("Escape")
print(bar.open_at)

# tree
print(len(tr.rows_list()))
app.click(tr.abs_x() + 6, tr.abs_y() + 5)
print(len(tr.rows_list()), nodes[0].open, picked)
app.click(tr.abs_x() + 40, tr.abs_y() + 2 + 12 + 5)
print(picked)
app.press("Down")
app.press("Right")
print(picked, len(tr.rows_list()))
app.press("Right")
print(tr.selected.label)
app.press("Left")
app.press("Left")
print(tr.selected.label, nodes[0].children[1].open)
app.press("End")
print(tr.selected.label)
app.press("Home")
app.press("Left")
print(nodes[0].open, len(tr.rows_list()))
tr.expand_all()
print(len(tr.rows_list()), tr.top)
app.scroll(tr.abs_x() + 5, tr.abs_y() + 5, 1)
print(tr.top)
tr.select(nodes[2])
print(tr.top, picked.pop())
tr.collapse_all()
print(len(tr.rows_list()), tr.top, app.snapshot() >= 0)
