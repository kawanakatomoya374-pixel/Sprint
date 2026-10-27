# gui layout demo: a settings screen built from row/column/grid containers, with
# a scroll view, a dark and a light theme, and an animation on the virtual clock.
# run:  sprint run --allow-write=build examples/gui_layout.sp
import gui

let status = gui.label("ready")
let volume = gui.slider(0, 100, 40)
let meter = gui.progress(40)
volume.on_change = w => meter.set_value(w.value)

let names = ["red", "green", "blue", "gold", "teal", "plum", "gray", "navy"]
let colors = gui.listbox(names, w => status.set_text("picked " .. w.current()), 3)
let name = gui.input("", "your name")
let log = gui.column([gui.label("log line " .. to_string(i)) for i in range(12)], 2, 4)

let ui = gui.column([
    gui.label("Settings", 2),
    gui.separator(),
    gui.grid(2, [
        gui.label("Name"), name,
        gui.label("Volume"), volume,
        gui.label("Level"), meter,
        gui.label("Colour"), colors
    ], 6, 0),
    gui.row([gui.checkbox("Notify", true), gui.spacer(), gui.button("Cancel"), gui.button("Save", w => status.set_text("saved"))], 6, 0),
    gui.scroll(log, 220, 44),
    status
], 8, 10)

let app = gui.App(260, 300, "settings")
app.fill(ui)
ui.framed = true
ui.align = "start"
app.click(name.abs_x() + 5, name.abs_y() + 5)
app.type_text("Ada")
app.drag(volume.abs_x() + 10, volume.abs_y() + 7, volume.abs_x() + 90, volume.abs_y() + 7)
app.click(colors.abs_x() + 5, colors.abs_y() + 25)
app.scroll(log.abs_x() + 5, log.abs_y() + 5, 2)
app.animate(40, 100, 200, v => meter.set_value(v), "in_out")
app.advance(100)
app.advance(100)
app.screenshot("build/gui_layout_dark.png")
app.set_theme("light")
app.screenshot("build/gui_layout_light.png")
print(name.text, volume.value, meter.value, colors.current(), status.text)
