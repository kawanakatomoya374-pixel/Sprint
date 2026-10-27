import gui

# column / row / flex
let a = gui.label("A")
let b = gui.label("BB")
let sp = gui.spacer()
let c = gui.button("Go")
let col = gui.column([a, gui.row([b, sp, c]), gui.separator()])
let app = gui.App(200, 100, "t")
app.add(col)
app.relayout()
print(col.w, col.h, a.x, a.y, a.w)
let r = col.children[1]
print(r.x, r.y, r.w, r.h, b.x, sp.w, c.x + c.w == r.w - 6)

# flex fills the window; weights split the remainder
let box = gui.row([gui.label("x"), gui.spacer(1), gui.spacer(3)], 0, 0)
let app2 = gui.App(100, 40)
app2.fill(box)
app2.relayout()
print(box.children[1].w, box.children[2].w, box.children[1].x, box.children[2].x)

# alignment and justify
let cc = gui.column([gui.label("ab"), gui.label("abcd")], 2, 0)
cc.align = "center"
cc.set_size(60, 40)
cc.justify = "end"
let app3 = gui.App(60, 40)
app3.add(cc)
app3.relayout()
print(cc.children[0].x, cc.children[1].x, cc.children[0].y, cc.children[1].y)

# grid
let g = gui.grid(2, [gui.label("a"), gui.label("bbb"), gui.label("cc"), gui.label("d")], 1, 0)
let app4 = gui.App(80, 40)
app4.add(g)
app4.relayout()
print(g.w, g.h, g.children[1].x, g.children[2].y, g.children[3].x)

# scroll view: wheel, keys, clipping
let items = [gui.label("row " .. to_string(i)) for i in range(20)]
let sv = gui.scroll(gui.column(items, 2, 2), 80, 50)
let app5 = gui.App(100, 80)
app5.add(sv)
app5.draw()
print(sv.content.h > sv.h, sv.max_scroll() > 0, sv.scroll_y)
app5.scroll(10, 10, 1)
app5.scroll(10, 10, 2)
print(sv.scroll_y)
app5.click(10, 10)
app5.press("End")
print(sv.scroll_y == sv.max_scroll())
app5.press("Home")
print(sv.scroll_y)
# pixels outside the viewport stay untouched by the clipped content
let cv = app5.draw()
print(cv.get(90, 70) == 0x23262e)

# theme switch changes the pixels, switching back restores them
let h_dark = app5.snapshot()
app5.set_theme("light")
let h_light = app5.snapshot()
app5.set_theme("dark")
print(h_dark != h_light, app5.snapshot() == h_dark)

# animation on the virtual clock
let seen = []
let bar = gui.progress(0)
app5.animate(0, 100, 100, func(v): seen.append(v), "linear", func(ap): seen.append("done"))
app5.advance(25)
app5.advance(25)
app5.advance(100)
print(seen)
let eased = []
app5.animate(0, 1000, 100, func(v): eased.append(v), "in")
app5.advance(50)
app5.advance(50)
print(eased)

# record / replay / trace round trip
func build():
    let ap = gui.App(120, 60)
    let t = gui.input("")
    let ck = gui.checkbox("ok")
    ap.add(gui.row([t, ck]))
    return [ap, t, ck]
let one = build()
one[0].draw()
one[0].start_recording()
one[0].click(20, 12)
one[0].type_text("hi")
one[0].advance(10)
let evs = one[0].stop_recording()
let two = build()
two[0].draw()
let text = gui.encode_trace(evs)
two[0].replay(gui.decode_trace(text))
print(len(evs), one[1].text, two[1].text, one[0].snapshot() == two[0].snapshot())
gui.expect_snapshot(two[0], one[0].snapshot(), "replay")
try:
    gui.expect_snapshot(two[0], 1, "bad")
catch e:
    print(e.kind)
print(one[0].draw().diff(two[0].draw()))
