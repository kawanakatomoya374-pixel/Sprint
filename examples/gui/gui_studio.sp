# A "studio" window built from guiplus: a paint surface driven by a colour picker and a brush-size
# slider, live charts of what was painted, a calendar and a status bar. Scripted events keep the
# output (and the screenshot) identical on every run.
import gui
import table
import guiplus as gp

let picker = gp.color_picker(0xe0585b)
let pie = gp.chart("donut", [{name: "colours", values: []}], [], 150, 110)
let bars = gp.chart("bar", [{name: "strokes", values: [0]}], ["total"], 150, 110)
let canvas = gp.canvas_view(150, 110, nil, 0xfafafa)
let strokes = []
let usage = {}
let brush = 3
let status = gp.StatusBar(["Ready", "0 strokes", "brush 3"])

func paint(v, k, x, y, b):
    if k == "up":
        return nil
    let col = picker.color()
    v.canvas.fill_circle(x, y, brush, col)
    if k == "down":
        strokes.append(col)
        let key = gp.hex_color(col)
        usage[key] = (usage[key] ?? 0) + 1
        refresh()

func refresh():
    let keys = table.keys(usage)
    keys.sort((a, b) => a < b)
    pie.set_series([{name: "colours", values: keys.map(k => usage[k])}])
    pie.labels = keys
    bars.set_series([{name: "strokes", values: [len(strokes)]}])
    status.set_text(1, to_string(len(strokes)) .. " strokes")

canvas.on_pointer = paint
let size = gui.slider(1, 9, 3, w => set_brush(w.value))
func set_brush(n):
    brush = n
    status.set_text(2, "brush " .. to_string(n))
let cal = gp.calendar(2026, 10, 21)
cal.today = [2026, 10, 21]
let tools = gp.toolbar([
    ["trash", a => clear_all(), "Clear canvas"], "-",
    ["plus", a => size.set_value(imin(9, brush + 2)), "Bigger brush"],
    ["minus", a => size.set_value(imax(1, brush - 2)), "Smaller brush"]
])
func imin(a, b):
    return a if a < b else b
func imax(a, b):
    return a if a > b else b
func clear_all():
    canvas.clear()
    strokes = []
    usage = {}
    refresh()

let left = gui.column([canvas, size, picker], 4, 4)
let right = gui.column([gui.row([pie, bars], 4, 0), cal], 4, 0)
let app = gui.App(480, 330, "studio")
app.fill(gui.column([tools, gui.row([left, right], 6, 4), status], 2, 2))
bars.tip = "strokes so far"

func stroke(x0, y0, x1, y1):
    let steps = 6
    app.dispatch(gui.mouse_move(canvas.abs_x() + x0, canvas.abs_y() + y0))
    app.dispatch(gui.mouse_down(canvas.abs_x() + x0, canvas.abs_y() + y0))
    for i in range(1, steps + 1):
        app.dispatch(gui.mouse_move(canvas.abs_x() + x0 + (x1 - x0) * i // steps, canvas.abs_y() + y0 + (y1 - y0) * i // steps))
    app.dispatch(gui.mouse_up(canvas.abs_x() + x1, canvas.abs_y() + y1))
    app.pump()

stroke(10, 10, 120, 60)
app.click(picker.abs_x() + 100, picker.abs_y() + 60)
stroke(10, 90, 130, 20)
app.press("Down")
app.press("Left")
stroke(30, 20, 30, 100)
app.click(tools.children[2].abs_x() + 5, tools.children[2].abs_y() + 5)
stroke(60, 50, 100, 50)
app.click(tools.children[0].abs_x() + 5, tools.children[0].abs_y() + 5)
stroke(20, 20, 110, 90)
app.click(cal.abs_x() + 100, cal.abs_y() + 60)
app.press("PageDown")
app.hover_at(pie.abs_x() + 75, pie.abs_y() + 70)
app.screenshot("build/gui_studio.png")
let used = table.keys(usage)
used.sort((a, b) => a < b)
print(len(strokes), used)
print(brush, picker.sat, picker.val, gp.hex_color(picker.color()))
print(cal.date(), cal.lead())
print(status.parts)
print(pie.describe([0, 0]), bars.describe([0, 0]))
print(app.snapshot() > 0)
