# gui demo: builds a small form, drives it with synthetic input, saves PNGs.
# run:  sprint run --allow-write=build examples/gui_demo.sp
import gui

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

app.click(60, 40)
app.type_text("Ada")
app.click(200, 40)
app.drag(50, 87, 120, 87)
app.click(30, 150)
app.draw().save_png("build/gui_demo.png")
print(greet.text, vol.value, list.current(), dark.checked)
