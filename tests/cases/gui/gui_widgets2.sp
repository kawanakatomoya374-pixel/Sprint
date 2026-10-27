import gui

let log = []
let tbl = gui.table([["Name", 90], ["Qty", 50], "Note"], [["pear", 3, "x"], ["apple", 12, "y"], ["fig", 7, "z"]], 220, 70, w => log.append(w.selected_row()[0]))
let sp = gui.spinner(5, 0, 12, 2, w => log.append("sp=" .. to_string(w.value)))
let rd = gui.radio(["red", "green", "blue"], 0, w => log.append("rd=" .. w.current()))
let left = gui.column([gui.label("left"), sp, rd])
let right = gui.column([tbl])
let split = gui.splitter(left, right, false, 90)
let app = gui.App(320, 120)
app.add(split)
split.set_size(320, 120)
app.relayout()
print(split.pos, left.w, right.w, right.x)

# table: sort by header, select, keyboard
print(tbl.order, tbl.col_w(2))
app.click(tbl.abs_x() + 20, tbl.abs_y() + 5)
print(tbl.order, tbl.sort_col, tbl.sort_desc)
app.click(tbl.abs_x() + 20, tbl.abs_y() + 5)
print(tbl.order, tbl.sort_desc)
app.click(tbl.abs_x() + 100, tbl.abs_y() + 5)
print(tbl.order)
app.click(tbl.abs_x() + 10, tbl.abs_y() + 15 + 12 + 3)
print(tbl.selected, log)
app.press("Down")
app.press("Home")
app.press("End")
app.press("Up")
print(tbl.selected_row(), log)
tbl.sort_by(0)
print(tbl.order)

# spinner
app.click(sp.abs_x() + sp.w - 5, sp.abs_y() + 3)
app.click(sp.abs_x() + sp.w - 5, sp.abs_y() + 14)
app.click(sp.abs_x() + sp.w - 5, sp.abs_y() + 14)
print(sp.value)
app.press("End")
app.press("Up")
print(sp.value)
app.press("PageDown")
app.press("PageDown")
print(sp.value, log)

# radio
app.click(rd.abs_x() + 5, rd.abs_y() + 14 + 3)
app.press("Down")
app.press("Down")
print(rd.selected, rd.current())

# splitter drag, clamped
let bx = split.abs_x() + split.pos + 2
app.drag(bx, 50, bx + 60, 50)
print(split.pos, left.w, right.w)
app.drag(split.abs_x() + split.pos + 2, 50, 2, 50)
print(split.pos)
app.drag(split.abs_x() + split.pos + 2, 50, 999, 50)
print(split.pos)
let vs = gui.splitter(gui.label("top"), gui.label("bottom"), true, 40)
vs.set_size(100, 100)
vs.layout()
print(vs.children[0].h, vs.children[1].y, vs.children[1].h)

# context menu
let acted = []
let btn = gui.button("ctx")
btn.context = [["One", a => acted.append(1)], "-", ["Two", a => acted.append(2)]]
let app2 = gui.App(160, 100)
app2.add(btn)
btn.x = 10
btn.y = 10
app2.right_click(15, 15)
print(app2.ctx != nil, app2.ctx.x, app2.ctx.y)
app2.press("Down")
app2.press("Down")
app2.press("Enter")
print(acted, app2.ctx == nil)
app2.right_click(15, 15)
app2.click(100, 90)
print(acted, app2.ctx == nil)
app2.context_menu(150, 95, [["A", a => acted.append(9)]])
print(app2.ctx.x, app2.ctx.y)
app2.click(app2.ctx.x + 5, app2.ctx.y + 5)
print(acted)
btn.context = b => [["dyn " .. b.text, a => acted.append(3)]]
app2.right_click(15, 15)
print(len(app2.ctx.entries), app2.ctx.entries[0][0])
app2.press("Escape")
print(app2.ctx == nil)

# tooltip and toast on the virtual clock
btn.tip = "Does a thing"
app2.hover_at(100, 60)
let away = app2.snapshot()
app2.hover_at(15, 15)
let near = app2.snapshot()
app2.advance(300)
print(app2.snapshot() == near, app2.hover_ms)
app2.advance(300)
let shown = app2.snapshot()
print(shown != near, app2.hover_ms)
app2.hover_at(100, 60)
print(app2.snapshot() == away)
app2.toast("saved", 1000)
print(app2.snapshot() != away, len(app2.toasts))
app2.advance(500)
app2.advance(600)
print(len(app2.toasts), app2.snapshot() == away)
