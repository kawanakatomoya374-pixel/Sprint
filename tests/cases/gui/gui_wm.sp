import gui
import wm
import proc
import window

# desktop: windows, z-order, drag, resize, maximise, minimise, close, taskbar, terminal, headless backend
let k = proc.Kernel()
let sh = proc.Shell(k)
sh.install("hello", (sys, args) => sys.print("hello " .. args.join(",")))
let d = wm.Desktop(320, 200)
let term = wm.Terminal(sh, 200, 80)
let ft = d.open_window("Terminal", 10, 10, 210, 100, term)
let fn = d.open_window("Notes", 100, 60, 150, 90, gui.Label("hello"))
d.set_clock("12:00")
let opened = []
d.add_icon("Files", 250, 10, ic => opened.append(ic.label))
let win = window.open(320, 200, "os")

func order():
    return d.wins.map(f => f.title).join(">")

print(order(), fn.active, ft.active)
# click the back window's visible part raises it
win.feed(gui.mouse_down(40, 60)).feed(gui.mouse_up(40, 60))
window.run(d, win)
print(order(), ft.active, fn.active)
# type into the terminal
win.feed(gui.mouse_down(40, 60)).feed(gui.mouse_up(40, 60))
win.feed(gui.text("mkdir /x")).feed(gui.key("Enter"))
win.feed(gui.text("hello a b")).feed(gui.key("Enter"))
win.feed(gui.text("ls /")).feed(gui.key("Enter"))
win.feed(gui.key("Up"))
window.run(d, win)
print(term.lines.slice(1, len(term.lines)), term.input)
# drag the Notes window by its title bar
win.feed(gui.mouse_down(130, 140)).feed(gui.mouse_up(130, 140))
win.feed(gui.mouse_down(120, 65)).feed(gui.mouse_move(150, 90)).feed(gui.mouse_up(150, 90))
window.run(d, win)
print(fn.x, fn.y, win.cursor)
# resize through the grip
win.feed(gui.mouse_down(fn.x + fn.w - 3, fn.y + fn.h - 3)).feed(gui.mouse_move(fn.x + fn.w + 17, fn.y + fn.h + 7))
window.run(d, win)
print(d.cursor_name())
win.feed(gui.mouse_up(fn.x + fn.w + 17, fn.y + fn.h + 7))
window.run(d, win)
print(fn.w, fn.h)
# double click the title bar: maximise, again: restore
win.feed(gui.mouse_down(fn.x + 20, fn.y + 5, 1, "", 2)).feed(gui.mouse_up(fn.x + 20, fn.y + 5))
window.run(d, win)
print(fn.state, fn.x, fn.y, fn.w, fn.h)
win.feed(gui.mouse_down(fn.x + 20, fn.y + 5, 1, "", 2)).feed(gui.mouse_up(fn.x + 20, fn.y + 5))
window.run(d, win)
print(fn.state, fn.x, fn.y, fn.w, fn.h)
# minimise via the button, restore via the taskbar
win.feed(gui.mouse_down(fn.x + fn.w - 27, fn.y + 6)).feed(gui.mouse_up(fn.x + fn.w - 27, fn.y + 6))
window.run(d, win)
print(fn.visible, fn.state, d.top().title)
win.feed(gui.mouse_down(130, 190)).feed(gui.mouse_up(130, 190))
window.run(d, win)
print(fn.visible, d.top().title)
# double click an icon
win.feed(gui.mouse_down(270, 20, 1, "", 2)).feed(gui.mouse_up(270, 20))
window.run(d, win)
print(opened)
# close the Notes window
win.feed(gui.mouse_down(fn.x + fn.w - 8, fn.y + 6)).feed(gui.mouse_up(fn.x + fn.w - 8, fn.y + 6))
window.run(d, win)
print(order(), len(d.root.children))
print(win.frames > 0, win.hashes[len(win.hashes) - 1] == d.canvas.hash())
