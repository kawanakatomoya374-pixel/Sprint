import gui

# tabs
let log = []
let pa = gui.column([gui.label("page A"), gui.button("a-btn")])
let pb = gui.column([gui.label("page B")])
let tb = gui.tabs(["One", "Two"], [pa, pb], w => log.append("tab=" .. to_string(w.selected)))
let dd = gui.dropdown(["red", "green", "blue"], 0, w => log.append("dd=" .. w.current()))
let ta = gui.textarea("ab\ncd", 3)
let ui = gui.column([tb, dd, ta])
let app = gui.App(220, 200)
app.fill(ui)
print(pa.visible, pb.visible)
app.click(tb.abs_x() + 5 + 40, tb.abs_y() + 8)
print(pa.visible, pb.visible, tb.selected)
app.press("Left")
print(tb.selected, log)

# dropdown: open, pick, escape, keys
app.click(dd.abs_x() + 5, dd.abs_y() + 5)
print(dd.is_open, app.popup == dd)
app.click(dd.abs_x() + 5, dd.abs_y() + dd.h + 2 + 12 * 2 + 3)
print(dd.is_open, dd.current(), app.popup == nil)
app.press("Up")
print(dd.current())
app.press("Enter")
app.press("Escape")
print(dd.is_open)
app.click(dd.abs_x() + 5, dd.abs_y() + 5)
app.click(2, 2)
print(dd.is_open, dd.current())

# text area editing
app.click(ta.abs_x() + 5, ta.abs_y() + 5)
app.press("End")
app.type_text("X")
app.press("Enter")
app.type_text("yz")
print(ta.text.replace("\n", "|"), ta.position())
app.press("Up")
app.press("Up")
print(ta.position())
app.press("Down")
app.press("Backspace")
print(ta.text.replace("\n", "|"))
for i in range(6):
    app.press("Enter")
print(ta.top > 0, ta.position()[0])

# modal dialog
let chosen = []
let d = gui.dialog(app, "Confirm", "Delete it?", ["Yes", "No"], i => chosen.append(i))
app.draw()
print(app.modal == d, d.x > 0, d.y > 0)
app.click(2, 2)
print(len(chosen), app.modal == d)
let yes = d.children[2].children[0]
app.click(yes.abs_x() + 3, yes.abs_y() + 3)
print(chosen, app.modal == nil)
gui.dialog(app, "Again", "ok?", ["OK"], i => chosen.append(i))
app.press("Escape")
print(chosen, app.modal == nil)
print(app.snapshot() >= 0)
