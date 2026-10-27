# A tiny operating-system session, entirely in Sprint: a kernel with processes, a file system, a shell
# in a terminal window, a desktop with draggable windows and a software mouse pointer, driven through
# the headless window backend. Pass a path to save a screenshot (needs --allow-write).
import gui
import proc
import vfs
import wm
import window
import sys

let kernel = proc.Kernel()
let shell = proc.Shell(kernel)
func clock(sys, args):
    sys.print("uptime " .. to_string(sys.now()) .. " ms")

func count(sys, args):
    for i in range(3):
        sys.print("tick " .. to_string(i))
        sys.sleep(10)

shell.install("clock", clock)
shell.install("count", count)

let desk = wm.Desktop(360, 220)
let term = wm.Terminal(shell, 230, 110)
desk.open_window("Terminal", 14, 14, 240, 130, term)
let info = gui.Label("Sprint OS\nKernel + VFS + WM")
desk.open_window("About", 170, 100, 150, 70, info)
desk.add_icon("Files", 300, 12, ic => term.print_line("(files not implemented)"))
desk.set_clock("09:41")

let win = window.open(360, 220, "Sprint OS")
func type_line(s):
    win.feed(gui.text(s)).feed(gui.key("Enter"))
win.feed(gui.mouse_down(40, 90)).feed(gui.mouse_up(40, 90))
for line in ["mkdir /home/user", "cd /home/user", "write notes.txt remember the milk", "cat notes.txt", "ls", "clock", "count", "tree /"]:
    type_line(line)
win.feed(gui.mouse_move(300, 150))
window.run(desk, win)
for l in term.lines:
    print(l)
print("frames:", win.frames, "pointer:", desk.cursor_name())
if len(sys.args) > 0:
    win.screenshot(sys.args[0])
