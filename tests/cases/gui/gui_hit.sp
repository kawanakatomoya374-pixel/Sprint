import gui
import gfx

# hit-test shapes, click-through widgets and mouse pointer shapes
let box = gui.Panel(10, 10, 40, 20)
box.shape_ellipse()
let rnd = gui.Panel(60, 10, 40, 40)
rnd.shape_round(12)
let tri = gui.Panel(110, 10, 40, 40)
tri.shape_polygon([[0, 39], [20, 0], [39, 39]])
let mk = gfx.canvas(40, 40, 0)
mk.fill_circle(20, 20, 10, 0xffffff)
let msk = gui.Panel(160, 10, 40, 40)
msk.shape_mask(mk, 0)
let under = gui.Button("under", 10, 60, 60, 20)
let glass = gui.Panel(5, 55, 120, 30)
glass.set_through(true)
let app = gui.App(220, 100)
for w in [box, rnd, tri, msk, under, glass]:
    app.add(w)

func probe(w, pts):
    return pts.map(p => w.hit_test(p[0], p[1]))

print(probe(box, [[30, 20], [11, 11], [49, 29], [30, 11]]))
print(probe(rnd, [[80, 30], [60, 10], [99, 49], [70, 12], [60, 30]]))
print(probe(tri, [[130, 40], [110, 12], [130, 12], [112, 48]]))
print(probe(msk, [[180, 30], [161, 11], [180, 20]]))
print(gui.in_polygon([[0, 0], [10, 0], [10, 10], [0, 10]], 5, 5), gui.in_polygon([[0, 0], [10, 0], [10, 10], [0, 10]], 12, 5))

# picking respects shapes and click-through
print(app.pick_at(11, 11) == app.root, app.pick_at(30, 20) == box)
print(app.pick_at(20, 70) == under, app.pick_at(120, 70) == app.root)

# pointer shapes follow the widget under the mouse
let ti = gui.TextInput(10, 85, 80)
app.add(ti)
app.show_cursor = true
app.hover_at(20, 70)
print(app.cursor_name())
app.hover_at(20, 90)
print(app.cursor_name())
app.hover_at(200, 90)
print(app.cursor_name())
box.pointer = "crosshair"
app.hover_at(30, 20)
print(app.cursor_name())
app.cursor_override = "wait"
print(app.cursor_name())
app.cursor_override = nil

# the software pointer is drawn into the frame, deterministically
app.hover_at(150, 80)
app.draw()
let h1 = app.snapshot()
app.show_cursor = false
app.needs_draw = true
app.draw()
print(h1 != app.snapshot())
app.show_cursor = true
app.hover_at(150, 80)
app.needs_draw = true
app.draw()
print(h1 == app.snapshot())
let names = []
for k, v in gui.cursors():
    names.append(k)
print(names)
