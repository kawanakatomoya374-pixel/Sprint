# Sprint OS: the desktop, a ring-3 process. It owns the framebuffer (mapped by the kernel), reads keyboard and
# mouse events through the input system call, and draws the window system (wm) and its applications. The
# shell and file system (proc, vfs) are plain Sprint libraries running inside this process.
import gdev
import io
import gui
import gfx
import guiplus as gp
import proc
import vfs
import wm
import psys
import urtc as rtc
import uinput

func log(s):
    print("[desktop] " .. s)
    io.flush()

let info = gdev.fb_map()
if info == nil:
    log("no framebuffer")
    psys.exit(1)
let W = info[0]
let H = info[1]
log("screen " .. to_string(W) .. "x" .. to_string(H))

let fs = vfs.FS()
let kernel = proc.Kernel(fs)
let shell = proc.Shell(kernel)
fs.mkdir("/home/user", true)
fs.mkdir("/etc", true)
fs.write("/etc/motd", "Welcome to Sprint OS.\nEverything you see - the drivers, the shell and this desktop - is written in Sprint.")
fs.write("/home/user/hello.txt", "Hello, world!")
fs.chdir("/home/user")

func hw_uname(sys, args):
    sys.print("SprintOS 0.2 x86_64 (Sprint " .. sys_version() .. ")")

func sys_version():
    return "2.8"

func hw_free(sys, args):
    let m = gdev.mem_info()
    sys.print("total " .. to_string(m[0] // 1048576) .. " MiB, free " .. to_string(m[1] // 1048576) .. " MiB")

func hw_uptime(sys, args):
    sys.print("up " .. to_string(psys.ms() // 1000) .. " s")

func hw_date(sys, args):
    sys.print(rtc.date_text())

func hw_poweroff(sys, args):
    log("poweroff")
    gdev.poweroff()

func hw_reboot(sys, args):
    log("reboot")
    gdev.reboot()

func hw_motd(sys, args):
    for l in fs.read("/etc/motd").split("\n"):
        sys.print(l)

shell.install("uname", hw_uname)
shell.install("free", hw_free)
shell.install("uptime", hw_uptime)
shell.install("date", hw_date)
shell.install("poweroff", hw_poweroff)
shell.install("reboot", hw_reboot)
shell.install("motd", hw_motd)

let desk = wm.Desktop(W, H)
desk.show_cursor = false          # the pointer is drawn by hw, straight onto the framebuffer

# ---- applications ------------------------------------------------------------------------------
let win_n = 0
func place():
    win_n += 1
    return [40 + (win_n % 6) * 28, 30 + (win_n % 6) * 24]

func func_log_cmd(line, out):
    log("$ " .. line .. " => " .. out.replace("\n", "|"))

func open_terminal(ic = nil):
    let p = place()
    let term = wm.Terminal(shell, 520, 300)
    term.print_line("Welcome to Sprint OS - type help")
    term.on_command = func_log_cmd
    desk.open_window("Terminal", p[0], p[1], 540, 330, term)
    log("open Terminal")
    return term

func open_notes(ic = nil, path = "/home/user/hello.txt"):
    let p = place()
    let ta = gui.textarea(fs.read(path) if fs.is_file(path) else "", 12)
    ta.set_flex(1)
    let status = gui.label(path)
    func save(b):
        fs.write(path, ta.text)
        status.set_text("saved " .. path)
        log("saved " .. path)
    let box = gui.column([gui.row([gui.button("Save", save), status], 6, 0), ta], 4, 4)
    desk.open_window("Notes", p[0], p[1], 460, 300, box)
    log("open Notes")

func open_files(ic = nil):
    let p = place()
    let cwd = "/home/user"
    let list = gui.listbox([], nil, 14)
    list.set_flex(1)
    let path_label = gui.label(cwd)
    func refresh():
        let names = fs.ls(cwd)
        let items = []
        if cwd != "/":
            items.append("..")
        for n in names:
            items.append(n .. ("/" if fs.is_dir(vfs.join(cwd, n)) else ""))
        list.items = items
        list.selected = -1
        list.dirty()
        path_label.set_text(cwd)
    func activate(l):
        let name = l.items[l.selected]
        if name == "..":
            cwd = vfs.dirname(cwd)
        elif name.ends_with("/"):
            cwd = vfs.join(cwd, name.slice(0, len(name) - 1))
        else:
            open_notes(nil, vfs.join(cwd, name))
        refresh()
    list.on_select = activate
    refresh()
    desk.open_window("Files", p[0], p[1], 300, 280, gui.column([path_label, list], 4, 4))
    log("open Files")

func open_monitor(ic = nil):
    let p = place()
    let up = gui.label("")
    let mem = gui.label("")
    let bar = gui.progress(0, 100)
    let procs = gui.label("")
    let hist = []
    let ch = gp.chart("area", [{name: "free MiB", values: [0, 0]}], [], 280, 110)
    let box = gui.column([up, mem, bar, procs, ch], 4, 6)
    let f = desk.open_window("System", p[0], p[1], 310, 270, box)
    func update():
        let m = gdev.mem_info()
        let used = (m[0] - m[1]) * 100 // m[0]
        up.set_text("uptime " .. to_string(psys.ms() // 1000) .. " s    " .. rtc.date_text())
        mem.set_text("memory " .. to_string((m[0] - m[1]) // 1048576) .. " / " .. to_string(m[0] // 1048576) .. " MiB")
        bar.set_value(used)
        procs.set_text("processes " .. to_string(len(kernel.ps())))
        hist.append(m[1] // 1048576)
        if len(hist) > 40:
            hist.remove_at(0)
        if len(hist) >= 2:
            ch.set_series([{name: "free MiB", values: hist.copy()}])
    update()
    func tick(a):
        if desk.wins.contains(f):
            update()
    desk.every(1000, tick)
    log("open System")

func open_paint(ic = nil):
    let p = place()
    let color = 0x1e90ff
    let down = false
    let last = [0, 0]
    func on_ptr(v, kind, x, y, button):
        if kind == "down":
            down = true
            last = [x, y]
            v.canvas.fill_circle(x, y, 2, color)
        elif kind == "move" and down:
            v.canvas.line(last[0], last[1], x, y, color)
            v.canvas.fill_circle(x, y, 2, color)
            last = [x, y]
        elif kind == "up":
            down = false
        v.dirty()
    let view = gp.canvas_view(300, 200, nil, 0xffffff)
    view.on_pointer = on_ptr
    func pick(w):
        color = w.color()
    func wipe(b):
        view.clear()
        view.dirty()
    let picker = gp.color_picker(color, pick)
    let clear = gui.button("Clear", wipe)
    desk.open_window("Paint", p[0], p[1], 330, 450, gui.column([view, picker, clear], 4, 4))
    log("open Paint")

func open_calendar(ic = nil):
    let p = place()
    let t = rtc.now()
    desk.open_window("Calendar", p[0], p[1], 230, 220, gp.calendar(t[0], t[1], t[2]))
    log("open Calendar")

func open_about(ic = nil):
    let p = place()
    let txt = gui.label("Sprint OS\n\nThe kernel, the drivers and this desktop\nare written in Sprint; the desktop runs\nin ring 3 as its own Sprint VM.", 1, 0)
    desk.open_window("About", p[0], p[1], 260, 140, gui.column([txt], 4, 8))
    log("open About")

desk.add_icon("Terminal", 20, 16, open_terminal)
desk.add_icon("Notes", 20, 74, open_notes)
desk.add_icon("Files", 20, 132, open_files)
desk.add_icon("System", 20, 190, open_monitor)
desk.add_icon("Paint", 20, 248, open_paint)
desk.add_icon("Calendar", 20, 306, open_calendar)
desk.add_icon("About", 20, 364, open_about)
desk.set_clock(rtc.clock_text())
func update_clock(a):
    desk.set_clock(rtc.clock_text())
desk.every(5000, update_clock)

# ---- the pointer ---------------------------------------------------------------------------------
let cursor_cache = {}
let cursor_now = ""
func set_pointer(name):
    if name == cursor_now:
        return nil
    cursor_now = name
    if not (name in cursor_cache):
        let c = gfx.canvas(24, 24, 0xFF00FF)
        gui.draw_cursor(c, name, 8, 8)
        cursor_cache[name] = c
    gdev.cursor_image(cursor_cache[name], 8, 8)

# ---- main loop ----------------------------------------------------------------------------------
let input = uinput.Input(W, H)
desk.draw()
gdev.present(desk.canvas)
set_pointer("arrow")
gdev.cursor_move(input.mx, input.my)
log("ready after " .. to_string(psys.ms()) .. " ms")

let last = psys.ms()
let frames = 0
while desk.running:
    let evs = input.poll()
    let moved = false
    for ev in evs:
        if ev.type == "mouse_move":
            moved = true
        desk.dispatch(ev)
    desk.pump()
    let now = psys.ms()
    if now - last >= 20:
        desk.dispatch(gui.tick(now - last))
        desk.pump()
        last = now
    if desk.needs_draw:
        desk.draw()
        let r = desk.last_rect
        gdev.present(desk.canvas, 0, 0, r[0], r[1], r[2], r[3])
        frames += 1
    if moved:
        gdev.cursor_move(input.mx, input.my)
        set_pointer(desk.cursor_name())
    if len(evs) == 0:
        psys.sleep_ms(4)
log("stopped after " .. to_string(frames) .. " frames")
