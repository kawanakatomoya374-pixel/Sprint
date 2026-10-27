import gui
import gfx

let app = gui.App(200, 120, "t")
let log = []
let b1 = app.add(gui.Button("A", 10, 10, 40, 16))
let b2 = app.add(gui.Button("B", 60, 10, 40, 16))
let cb = app.add(gui.Checkbox("c", 10, 40, false))
let sl = app.add(gui.Slider(10, 60, 100, 0, 10, 5))
let ti = app.add(gui.TextInput(10, 80, 100))
let lb = app.add(gui.ListBox(120, 10, 60, 40, ["x", "y", "z"]))
b1.name = "one"
func hit_a(w):
    log.append("A")
func hit_b(w):
    log.append("B")
b1.on_click = hit_a
b2.on_click = hit_b
cb.on_change = func(w): log.append("cb=" .. to_string(w.checked))
sl.on_change = func(w): log.append("sl=" .. to_string(w.value))
ti.on_change = func(w): log.append("ti=" .. w.text)
lb.on_select = func(w): log.append("lb=" .. to_string(w.current()))

app.click(15, 15)
app.click(65, 15)
app.click(500, 500)  # misses everything
print(log, app.focus == b2)
# press inside, release outside: no click
app.dispatch(gui.mouse_down(15, 15))
app.dispatch(gui.mouse_up(150, 100))
print(len(log), b1.pressed)
# keyboard focus walk
app.set_focus(nil)
app.press("Tab")
app.press("Tab")
app.press("Tab")
print(app.focus == cb)
app.press("Space")
app.press("Tab")
print(app.focus == sl)
app.press("Right")
app.press("End")
print(sl.value)
app.press("Home")
print(sl.value)
app.press("ShiftTab")
print(app.focus == cb)
app.click(20, 85)
app.type_text("héllo!")
app.press("Left")
app.press("Backspace")
app.press("Delete")
print(ti.text, ti.cursor)
app.press("Home")
app.type_text("> ")
print(ti.text)
app.click(125, 30)
app.press("Down")
app.press("Down")
app.press("Down")
print(lb.current(), lb.selected)
print(log)
# disabled widgets ignore input
b1.set_enabled(false)
let n = len(log)
app.click(15, 15)
print(len(log) == n)
# find / pick / abs
print(app.find("one") == b1, app.root.pick(15, 15) == b1, app.root.pick(190, 110) == app.root)
# timers on a virtual clock
let fired = []
app.after(100, func(a): fired.append(a.now))
app.every(40, func(a): fired.append(-a.now))
app.dispatch(gui.tick(50))
app.dispatch(gui.tick(60))
app.dispatch(gui.tick(100))
print(fired)
# run loop: events from a function, stops at nil and on quit
let evs = [gui.mouse_move(1, 1), gui.key("Tab"), gui.quit_event(), gui.key("Tab")]
let idx = 0
func source():
    if idx >= len(evs):
        return nil
    idx += 1
    return evs[idx - 1]
let frames = []
app.run(source, func(a): frames.append(a.frames))
print(app.running, idx, len(frames) > 0)
# determinism: same events -> same pixels
func checksum(c):
    let h = 7
    for y in range(c.height()):
        for x in range(c.width()):
            h = (h * 31 + c.get(x, y)) % 1000003
    return h
let a1 = checksum(app.draw())
let a2 = checksum(app.draw())
print(a1 == a2, a1)
try:
    app.dispatch({type: "bogus"})
catch e:
    print(e.kind, e.message)
# layout helpers
let ws = [gui.Label("ab", 0, 0), gui.Label("cde", 0, 0)]
print(gui.vstack(ws, 4, 5, 2), ws[1].y, gui.hstack(ws, 1, 1, 3), ws[1].x)
