import gui

let changes = []
let ti = gui.TextInput(0, 0, 90, "hello world", w => changes.append(w.text))
let ta = gui.textarea("one two\nthree four\nfive", 4)
let ui = gui.column([ti, ta])
let app = gui.App(240, 140)
app.fill(ui)

# select, replace, clipboard
app.click(ti.abs_x() + 5, ti.abs_y() + 5)
app.press("Ctrl+A")
print(ti.selected_text(), ti.has_selection())
app.press("Ctrl+C")
print(app.clipboard)
app.type_text("bye")
print(ti.text, ti.cursor, ti.has_selection())
app.press("Ctrl+V")
print(ti.text)
app.press("Ctrl+Z")
print(ti.text)
app.press("Ctrl+Z")
print(ti.text)
app.press("Ctrl+Shift+Z")
print(ti.text)
app.press("Ctrl+Y")
print(ti.text, len(changes))

# shift selection and word movement
ti.set_text("alpha beta  gamma")
app.press("Home")
app.press("Shift+Right")
app.press("Shift+Right")
print(ti.selected_text())
app.press("Left")
print(ti.cursor, ti.has_selection())
app.press("Ctrl+Right")
print(ti.cursor)
app.press("Ctrl+Shift+Right")
print(ti.selected_text())
app.press("Ctrl+Backspace")
print(ti.text)
app.press("End")
app.press("Ctrl+Backspace")
print(ti.text)
app.press("Ctrl+Delete")
app.press("Home")
app.press("Ctrl+Delete")
print(ti.text)

# mouse: double click selects a word, triple the whole line; shift-click extends; drag selects
ti.set_text("one two three")
app.double_click(ti.abs_x() + 4 + 5 * 6, ti.abs_y() + 5)
print(ti.selected_text())
app.triple_click(ti.abs_x() + 4 + 5 * 6, ti.abs_y() + 5)
print(ti.selected_text())
app.click(ti.abs_x() + 4 + 3 * 6, ti.abs_y() + 5)
app.click_with(ti.abs_x() + 4 + 7 * 6, ti.abs_y() + 5, "Shift")
print(ti.selected_text())
app.drag(ti.abs_x() + 4, ti.abs_y() + 5, ti.abs_x() + 4 + 3 * 6, ti.abs_y() + 5)
print(ti.selected_text())

# limits, read-only, password, scrolling a long text
let lim = gui.TextInput(0, 0, 60, "")
lim.max_len = 5
app.add(lim)
lim.x = 100
lim.y = 100
app.click(lim.abs_x() + 5, lim.abs_y() + 5)
app.type_text("abcdefgh")
print(lim.text)
lim.readonly = true
app.type_text("zz")
app.press("Backspace")
print(lim.text)
lim.readonly = false
lim.password = true
lim.set_text("secret pass phrase")
print(lim.first, lim.cursor)
app.press("Home")
print(lim.first)

# text area: multi-line selection, up/down, cut/paste, undo, horizontal scroll
app.click(ta.abs_x() + 5, ta.abs_y() + 5)
app.press("Ctrl+Home")
app.press("Shift+Down")
app.press("Shift+End")
print(ta.selected_text().replace("\n", "|"))
app.press("Ctrl+X")
print(ta.text.replace("\n", "|"), app.clipboard.replace("\n", "|"))
app.press("Ctrl+End")
app.press("Ctrl+V")
print(ta.text.replace("\n", "|"), ta.position())
app.press("Ctrl+Z")
print(ta.text.replace("\n", "|"))
app.triple_click(ta.abs_x() + 5, ta.abs_y() + 3 + 10 + 5)
print(ta.selected_text())
ta.set_text("x".repeat(60))
print(ta.left, ta.cursor)
app.press("Home")
print(ta.left)
print(gui.parse_key("Ctrl+Alt+Shift+Left"), gui.parse_key("Ctrl++"), gui.parse_key("+"), gui.parse_key("Enter"))

# shortcuts
let hits = []
app.bind("Ctrl+S", a => hits.append("save"))
app.bind("F5", a => hits.append("run"))
app.press("Ctrl+S")
app.press("F5")
app.unbind("F5")
app.press("F5")
print(hits)
