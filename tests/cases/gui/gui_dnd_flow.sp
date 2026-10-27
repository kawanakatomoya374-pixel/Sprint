import gui

# flow wraps, stack overlays, expander folds
let chips = [gui.button("chip" .. to_string(i)) for i in range(7)]
let fl = gui.flow(chips, 4, 4, 4)
let st = gui.stack([gui.panel("back", gui.label("x")), gui.label("front")])
let inner = gui.column([gui.label("hidden?"), gui.label("body line")])
let ex = gui.expander("Details", inner, false)
let ui = gui.column([fl, st, ex])
let app = gui.App(200, 170)
let log = []
ex.on_toggle = w => log.append(w.is_open)
app.fill(ui)
print(fl.w, fl.h, ex.is_open, inner.visible)
let ys = []
for ch in chips:
    ys.append(ch.y)
print(ys)
print(fl.rows_for(100).map(r => len(r)), fl.rows_for(1000).map(r => len(r)))
fl.hgap = 40
app.relayout()
print(fl.h, chips[6].y, fl.rows_for(fl.w).map(r => len(r)))
print(st.children[0].w == st.w, st.children[1].h == st.h)
app.click(ex.abs_x() + 20, ex.abs_y() + 5)
print(ex.is_open, inner.visible, ex.h, log)
app.press("Left")
print(ex.is_open, log)
app.press("Right")
app.press("Space")
print(ex.is_open, ex.pref(), log)

# drag and drop between lists
let a = gui.listbox(["red", "green", "blue"], nil, 4)
let b = gui.listbox([], nil, 4)
a.drag_data = w => w.current()
a.drag_label = "item"
let got = []
func accept(target, data, src):
    target.items.append(data)
    got.append(data)
b.on_drop = accept
b.drop_ok = (target, data) => data != "blue"
let app2 = gui.App(200, 100)
app2.add(a)
app2.add(b)
a.x = 4
a.y = 4
a.set_size(80, 60)
b.x = 100
b.y = 4
b.set_size(80, 60)
app2.relayout()
app2.click(a.abs_x() + 10, a.abs_y() + 2 + 10 + 3)
print(a.current())
let h0 = app2.snapshot()
app2.dispatch(gui.mouse_move(a.abs_x() + 10, a.abs_y() + 15))
app2.dispatch(gui.mouse_down(a.abs_x() + 10, a.abs_y() + 15))
app2.dispatch(gui.mouse_move(a.abs_x() + 12, a.abs_y() + 15))
print(app2.drag_on)
app2.dispatch(gui.mouse_move(b.abs_x() + 20, b.abs_y() + 20))
print(app2.drag_on, app2.drag_payload, app2.drop_hot == b, app2.snapshot() != h0)
app2.dispatch(gui.mouse_up(b.abs_x() + 20, b.abs_y() + 20))
print(got, b.items, app2.drag_on, a.selected)
# a refused drop and an Escape cancel
a.select(2)
app2.dispatch(gui.mouse_move(a.abs_x() + 10, a.abs_y() + 2 + 20 + 3))
app2.dispatch(gui.mouse_down(a.abs_x() + 10, a.abs_y() + 2 + 20 + 3))
app2.dispatch(gui.mouse_move(b.abs_x() + 20, b.abs_y() + 20))
print(app2.drag_on, app2.drag_payload, app2.drop_hot == nil)
app2.dispatch(gui.mouse_up(b.abs_x() + 20, b.abs_y() + 20))
print(got)
app2.dispatch(gui.mouse_move(a.abs_x() + 10, a.abs_y() + 15))
app2.dispatch(gui.mouse_down(a.abs_x() + 10, a.abs_y() + 15))
app2.dispatch(gui.mouse_move(b.abs_x() + 20, b.abs_y() + 20))
app2.press("Escape")
app2.dispatch(gui.mouse_up(b.abs_x() + 20, b.abs_y() + 20))
print(app2.drag_on, got)
# a short move is just a click
let clicked = []
let btn = gui.button("go", w => clicked.append(1))
btn.drag_data = "x"
let app3 = gui.App(100, 60)
app3.add(btn)
btn.x = 10
btn.y = 10
app3.click(15, 15)
print(clicked, app3.drag_on)
app3.drag(15, 15, 60, 40)
print(clicked)
