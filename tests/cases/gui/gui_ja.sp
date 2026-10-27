import gui
import gfx

# Japanese in gui: widths, wrapping, editing on character boundaries
let ti = gui.TextInput(0, 0, 100, "")
let lbl = gui.Label("日本語 abc")
let wr = gui.Label("日本語のテキストを折り返す test", 0, 0).set_wrap(60)
let ta = gui.textarea("日本語\nabc\nかな", 4)
let pw = gui.TextInput(0, 0, 100, "")
pw.password = true
let ui = gui.column([ti, lbl, wr, ta, pw])
let app = gui.App(240, 200)
app.fill(ui)

print(lbl.h, gfx.text_advance("日本語 abc"))
print(wr.shown)
print(gui.wrap_lines("abc def ghi", 7))

app.click(ti.abs_x() + 5, ti.abs_y() + 5)
app.type_text("日本語abc")
print(ti.text, ti.cursor, len(ti.text))
app.press("Left")
app.press("Left")
app.press("Left")
app.press("Left")
print(ti.cursor)
app.press("Backspace")
print(ti.text, ti.cursor)
app.press("Delete")
print(ti.text, ti.cursor)
app.press("Shift+Right")
print(ti.selected_text())
app.press("Home")
app.press("Ctrl+Right")
print(ti.cursor)
ti.set_text("")
app.type_text("é\u{1F600}x")
print(ti.text)
ti.max_len = 3
ti.set_text("")
app.type_text("日本語漢字")
print(ti.text)
ti.max_len = 0

# clicking places the caret on a boundary
ti.set_text("日本語")
app.click(ti.abs_x() + 4 + 13, ti.abs_y() + 5)
print(ti.cursor)
app.click(ti.abs_x() + 4 + 30, ti.abs_y() + 5)
print(ti.cursor)

# scrolling keeps the caret visible
ti.set_text("日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語")
print(ti.first > 0, ti.cursor, ti.first % 3)
app.press("Home")
print(ti.first)

# password: one star per character
app.click(pw.abs_x() + 5, pw.abs_y() + 5)
app.type_text("日本a")
print(pw.text, pw.cursor, pw.vis())
app.press("Left")
app.press("Backspace")
print(pw.text, pw.cursor)

# text area: up/down keeps the pixel column
app.click(ta.abs_x() + 5, ta.abs_y() + 5)
app.press("Ctrl+Home")
app.press("Right")
app.press("Right")
app.press("Down")
print(ta.position())
app.press("Down")
print(ta.position())
app.press("Up")
print(ta.position())
app.press("Ctrl+End")
app.press("Backspace")
print(ta.text.replace("\n", "|"), ta.position())
app.draw()
print(app.snapshot() != 0)
