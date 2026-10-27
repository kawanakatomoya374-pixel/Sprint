import gui

# Partial (damage rectangle) redraws must give exactly the pixels of a full redraw.
func make():
    let count = gui.state(0)
    let lbl = gui.label_of(count, func(n): "count " .. to_string(n))
    let btn = gui.button("+1", func(b): count.update(func(n): n + 1))
    let sl = gui.slider_of(0, 10, count)
    let cb = gui.checkbox("on", false)
    let inp = gui.input("abc")
    let prog = gui.progress_of(count, 10)
    let items = [to_string(i) .. " item" for i in range(30)]
    let lb = gui.listbox(items, nil, 5)
    let sc = gui.scroll(gui.column([gui.label("line " .. to_string(i)) for i in range(40)]), 120, 80)
    let ap = gui.show(gui.column([lbl, btn, sl, cb, inp, prog, lb, sc]), "damage", 200, 300)
    return [ap, btn, sl, cb, inp, lb, sc, count]

let a = make()
let b = make()
let ok = true
let steps = 0
let partial = 0
func same(tag):
    a[0].draw()
    if a[0].last_rect[2] * a[0].last_rect[3] < a[0].width * a[0].height:
        partial += 1
    b[0].redraw()
    b[0].draw()
    steps += 1
    if a[0].canvas.hash() != b[0].canvas.hash():
        print("MISMATCH after", tag)
        ok = false

same("start")
for k in range(3):
    for t in [a, b]:
        t[0].click(t[1].abs_x() + 4, t[1].abs_y() + 4)
    same("click " .. to_string(k))
for t in [a, b]:
    t[0].click(t[3].abs_x() + 3, t[3].abs_y() + 3)
same("checkbox")
for t in [a, b]:
    t[4].set_text("hello world")
    t[4].dirty()
same("text")
for t in [a, b]:
    t[0].hover_at(t[2].abs_x() + 30, t[2].abs_y() + 3)
same("hover slider")
for t in [a, b]:
    t[0].hover_at(t[5].abs_x() + 10, t[5].abs_y() + 12)
same("hover list")
for t in [a, b]:
    t[0].click(t[5].abs_x() + 10, t[5].abs_y() + 22)
same("list click")
for t in [a, b]:
    t[0].scroll(t[6].abs_x() + 10, t[6].abs_y() + 10, 3)
same("wheel")
print(ok, steps, partial >= 5)
