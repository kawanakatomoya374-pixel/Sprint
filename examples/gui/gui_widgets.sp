# gui widgets demo: tabs, dropdown (open), text area and a modal dialog.
# run:  sprint run --allow-write=build examples/gui_widgets.sp
import gui

let mode = gui.dropdown(["Fast", "Balanced", "Careful"], 1)
let notes = gui.textarea("first line\nsecond line", 4)
let general = gui.column([gui.label("Mode"), mode, gui.label("Notes"), notes], 4, 8)
let about = gui.column([gui.label("Sprint GUI", 2), gui.label("headless, deterministic")], 4, 8)
let ui = gui.tabs(["General", "About"], [general, about])
let app = gui.App(240, 220, "widgets")
app.fill(ui)
app.click(notes.abs_x() + 20, notes.abs_y() + 8)
app.press("End")
app.type_text(" (edited)")
app.click(mode.abs_x() + 4, mode.abs_y() + 4)
app.screenshot("build/gui_widgets_open.png")
app.click(mode.abs_x() + 4, mode.abs_y() + mode.h + 2 + 24 + 3)
gui.dialog(app, "Confirm", "Apply " .. mode.current() .. " mode?", ["Apply", "Cancel"])
app.screenshot("build/gui_widgets_dialog.png")
print(mode.current(), notes.text.replace("\n", "|"))
