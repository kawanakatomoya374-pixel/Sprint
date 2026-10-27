import gui

# draggable scrollbars on list, table, tree, text area and scroll view; wrapped labels
let items = [to_string(i) for i in range(40)]
let lb = gui.listbox(items, nil, 6)
lb.set_size(80, 64)
let rows = [[i, "r" .. to_string(i)] for i in range(30)]
let tb = gui.table(["n", "name"], rows, 100, 64)
let ta = gui.textarea(items.slice(0, 20).join("\n"), 5)
ta.set_size(100, 46)
let big = gui.column([gui.label("line " .. to_string(i)) for i in range(30)], 2, 2)
let sv = gui.scroll(big, 90, 60)
let app = gui.App(420, 150)
let ui = gui.row([lb, tb, ta, sv], 6, 6)
ui.align = "start"
app.fill(ui)

func drag_bar(w, y0, h, total, vis, from_top, to_top):
    # drag the thumb: grab it at its centre row, move to where `to_top` would put it
    let th = w.bar_thumb(total, vis, from_top, h)
    let bx = w.abs_x() + w.w - 6
    let gy = y0 + th[0] + th[1] // 2
    let t2 = w.bar_thumb(total, vis, to_top, h)
    app.drag(bx, gy, bx, y0 + t2[0] + th[1] // 2)

print(lb.top, tb.top, ta.top, sv.scroll_y)
# list box: press the track below the thumb jumps there, dragging moves it
app.click(lb.abs_x() + lb.w - 5, lb.abs_y() + lb.h - 6)
print(lb.top, lb.bar_grab)
drag_bar(lb, lb.abs_y() + 2, lb.h - 4, 40, lb.rows(), lb.top, 3)
print(lb.top)
lb.top = 0
app.drag(lb.abs_x() + lb.w - 5, lb.abs_y() + 4, lb.abs_x() + lb.w - 5, lb.abs_y() + 4 + 20)
print(lb.top > 0, lb.selected)

# table: the strip right of the cells; header clicks next to the bar still sort
app.drag(tb.abs_x() + tb.w - 5, tb.abs_y() + 20, tb.abs_x() + tb.w - 5, tb.abs_y() + 50)
print(tb.top > 0, tb.sort_col)
app.click(tb.abs_x() + 10, tb.abs_y() + 5)
print(tb.sort_col)

# text area: dragging the bar scrolls without moving the caret
let before = ta.cursor
app.drag(ta.abs_x() + ta.w - 5, ta.abs_y() + 6, ta.abs_x() + ta.w - 5, ta.abs_y() + 30)
print(ta.top > 0, ta.cursor == before)

# scroll view: thumb drag and track click
let max = sv.max_scroll()
app.drag(sv.abs_x() + sv.w - 5, sv.abs_y() + 4, sv.abs_x() + sv.w - 5, sv.abs_y() + sv.h - 2)
print(sv.scroll_y == max, big.y == -max)
app.click(sv.abs_x() + sv.w - 5, sv.abs_y() + 2)
print(sv.scroll_y < max)
app.click(sv.abs_x() + sv.w - 5, sv.abs_y() + 2)
app.click(sv.abs_x() + sv.w - 5, sv.abs_y() + 2)
print(sv.scroll_y)

# wrapped and aligned labels
let wl = gui.label("the quick brown fox jumps over the lazy dog", 1, 60)
print(wl.shown, wl.w, wl.h)
wl.align = "center"
let rl = gui.Label("a\nbb\nccc")
rl.align = "right"
print(rl.shown, rl.w, rl.h)
print(gui.wrap_lines("averyveryverylongword and more", 8))
print(gui.wrap_lines("", 5), gui.wrap_lines("a  b", 5))
print(app.snapshot() > 0)
