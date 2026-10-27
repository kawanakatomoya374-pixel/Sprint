import gfx
import gui
import guiplus as gp
# behaviour probe
let picked = []
let ch = gp.chart("bar", [{name: "a", values: [3, 5, 4]}], ["x", "y", "z"], 200, 120)
ch.on_pick = w => picked.append(w.selected)
let pk = gp.color_picker(0xff0000, w => picked.append(w.color()))
let cal = gp.calendar(2024, 2, 28, w => picked.append(w.date()))
let cv = gp.canvas_view(60, 40)
let evs = []
cv.on_pointer = (v, k, x, y, b) => evs.append([k, x, y, b])
let ib = gp.IconButton("plus", w => picked.append("btn"), "add")
let ui = gui.column([ch, pk, cal, cv, ib], 4, 4)
let app = gui.App(300, 520)
app.fill(ui)
app.draw()
let p = ch.point_pos(0, 1)
app.click(ch.abs_x() + p[0], ch.abs_y() + p[1] + 5)
print(picked, ch.describe(ch.selected))
app.click(pk.abs_x() + 50, pk.abs_y() + 50)
print(pk.hue, pk.sat, pk.val, gp.hex_color(pk.color()))
app.press("Right")
print(pk.sat)
app.click(cal.abs_x() + 100, cal.abs_y() + 60)
print(cal.date())
app.click(cal.abs_x() + 10, cal.abs_y() + 8)
print(cal.date())
app.press("Down")
print(cal.date(), cal.lead())
app.dispatch(gui.mouse_move(cv.abs_x() + 5, cv.abs_y() + 6))
app.dispatch(gui.mouse_down(cv.abs_x() + 5, cv.abs_y() + 6))
app.dispatch(gui.mouse_move(cv.abs_x() + 20, cv.abs_y() + 9))
app.dispatch(gui.mouse_up(cv.abs_x() + 20, cv.abs_y() + 9))
print(evs)
app.click(ib.abs_x() + 5, ib.abs_y() + 5)
print(picked[len(picked) - 1])
for d in [[2024, 2, 29], [2000, 1, 1], [1970, 1, 1], [2026, 12, 31]]:
    print(gp.days_from_civil(d[0], d[1], d[2]), gp.civil_from_days(gp.days_from_civil(d[0], d[1], d[2])), gp.weekday(d[0], d[1], d[2]))

# icons: every name draws something, unknown names are rejected
let cnv = gfx.canvas(16, 16, 0)
for nm in gp.ICONS:
    cnv.clear(0)
    gp.icon(cnv, nm, 2, 2, 12, 0xffffff)
    print(nm, cnv.hash() != gfx.canvas(16, 16, 0).hash())
try:
    gp.icon(cnv, "nope", 0, 0, 12, 1)
catch e:
    print(e.message)

# chart kinds and geometry
let ch2 = gp.chart("line", [[1, 4, 2, 8], {name: "b", values: [2, 2, 3, 3], color: 0xff0000}], ["a", "b", "c", "d"], 200, 120)
print(ch2.y_range(), ch2.legend_items(), ch2.show_legend(), ch2.count())
let hashes = []
let ap2 = gui.App(210, 130)
ap2.fill(ch2)
for k in ["line", "area", "bar", "scatter"]:
    ch2.kind = k
    if k == "scatter":
        ch2.set_series([{name: "p", values: [[0, 0], [5, 5], [10, 2]]}])
    hashes.append(ap2.snapshot())
ch2.kind = "pie"
ch2.set_series([{name: "p", values: [1, 1, 2]}])
ch2.labels = ["a", "b", "c"]
print(ch2.slice_degrees(), ch2.legend_items())
hashes.append(ap2.snapshot())
ch2.kind = "donut"
hashes.append(ap2.snapshot())
print(hashes)
let seen = {}
for h in hashes:
    seen[to_string(h)] = true
print(len(seen))
ap2.hover_at(ch2.abs_x() + 100, ch2.abs_y() + 60)
print(ap2.snapshot() != hashes[5])
