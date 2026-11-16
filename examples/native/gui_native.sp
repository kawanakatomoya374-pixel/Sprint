# gui native (interactive, not run by make test): the settings form in a real window (X11 on Linux).
# run:  sprint run --allow-window examples/native/gui_native.sp
# Click the name field, type, press Greet; close the window (or press Escape) to quit.
import gui
import window

let app = gui.App(280, 190, "settings")
let panel = app.add(gui.Panel(8, 8, 264, 174, "Settings"))
let name = panel.add(gui.TextInput(12, 24, 150, ""))
name.placeholder = "your name"
let greet = gui.Label("", 12, 150)
let ok = gui.Button("Greet", 172, 22, 80, 20)
let dark = gui.Checkbox("Notifications", 12, 48, true)
let vol = gui.Slider(12, 72, 160, 0, 100, 30)
let volv = gui.Label("30", 182, 74)
let bar = gui.ProgressBar(12, 96, 240, 10, 30)
let list = gui.ListBox(12, 112, 120, 34, ["red", "green", "blue", "gold"])
panel.add(greet)
panel.add(ok)
panel.add(dark)
panel.add(vol)
panel.add(volv)
panel.add(bar)
panel.add(list)

ok.on_click = func(b): greet.set_text("Hello, " .. name.text .. "!")
func vol_changed(s):
    volv.set_text(to_string(s.value))
    bar.set_value(s.value)
vol.on_change = vol_changed
func quit_app(a):
    a.running = false
app.keymap["Escape"] = quit_app

let win = window.open(280, 190, "Sprint settings", "x11")
let shown = window.run(app, win)
print("frames", shown, "greeting:", greet.text)
