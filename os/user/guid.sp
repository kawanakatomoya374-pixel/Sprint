# Sprint OS: guid, the GUI server, a ring-3 process. It owns the framebuffer (mapped by the kernel), reads keyboard and
# mouse events through the input system call, draws the window system (wm) with its built-in applications, and serves
# other processes over messages (name "gui", see guiclient.sp): a client draws into a buffer it shares with guid, guid frames
# the window and sends the pointer and keyboard events back. The kernel knows nothing about windows.
import gdev
import ipc
import fsclient
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
    print("[guid] " .. s)
    io.flush()

# the display: the GPU server (gpud, a VirtIO-GPU) if the machine has one, else the kernel's framebuffer
let gpu = nil
let info = nil
let gpu_pid = nil
for i in range(20):
    gpu_pid = ipc.lookup("gpu")
    if gpu_pid != nil:
        break
    psys.sleep_ms(50)
if gpu_pid != nil:
    io.flush()
    ipc.send(gpu_pid, "info")
    while true:
        let m = ipc.recv_from()
        if m[0] != gpu_pid:
            continue
        let r = m[1].split("\t")
        if r[0] == "ok":
            let seg = ipc.shm_open(to_int(r[4]))
            gdev.fb_use(seg[0], to_int(r[1]), to_int(r[2]), to_int(r[3]))
            info = [to_int(r[1]), to_int(r[2])]
            gpu = gpu_pid
            log("display: VirtIO-GPU through gpud")
        else:
            log("no GPU (" .. r[2] .. "): using the kernel framebuffer")
        break
if info == nil:
    info = gdev.fb_map()
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

# the disk: the file system server (fsd) is another process; these commands talk to it over messages
let disk = nil
func disk_conn():
    if disk == nil:
        disk = fsclient.connect(1500)
    return disk

func disk_path(args, i, default):
    return args[i] if len(args) > i else default

func hw_dls(sys, args):
    try:
        for e in disk_conn().listdir(disk_path(args, 0, "/")):
            sys.print(("d " if e.kind == "dir" else "- ") .. to_string(e.size) .. "\t" .. e.name)
    catch e:
        sys.print("dls: " .. e.message)

func hw_dcat(sys, args):
    try:
        for l in disk_conn().read_file(disk_path(args, 0, "/")).split("\n"):
            sys.print(l)
    catch e:
        sys.print("dcat: " .. e.message)

func hw_dput(sys, args):
    if len(args) < 2:
        sys.print("usage: dput PATH TEXT...")
        return nil
    try:
        disk_conn().write_file(args[0], args.slice(1, len(args)).join(" ") .. "\n")
        disk_conn().sync()
        sys.print("wrote " .. args[0])
    catch e:
        sys.print("dput: " .. e.message)

shell.install("dls", hw_dls)
shell.install("dcat", hw_dcat)
shell.install("dput", hw_dput)

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

# ---- windows of other processes (the GUI protocol) ---------------------------------------------------------
# A client process draws into a shared buffer; this widget shows a copy of it and turns its own events into messages for the client.
class RemoteView extends gui.Widget:
    let win = nil
    override func init(self, win):
        super(0, 0, win.w, win.h)
        self.win = win
        self.focusable = true
    override func draw_self(self, c, ax, ay):
        c.blit(self.win.canvas, ax, ay)
    func ptr(self, kind, px, py, button):
        send_event(self.win, "ptr\t" .. kind .. "\t" .. to_string(px - self.abs_x()) .. "\t" .. to_string(py - self.abs_y()) .. "\t" .. to_string(button))
    override func on_mouse_down(self, px, py, button):
        self.pressed = true
        self.ptr("down", px, py, button)
    override func on_drag(self, px, py):
        if self.pressed:
            self.ptr("move", px, py, 1)
    override func on_mouse_up(self, px, py, button, inside):
        if self.pressed:
            self.pressed = false
            self.ptr("up", px, py, button)
    override func on_key(self, k):
        send_event(self.win, "key\t" .. k)
    override func on_text(self, s):
        send_event(self.win, "text\t" .. s)

let remote = {}        # window id -> {id, pid, w, h, canvas, seg, view, frame}
let next_win = 1

func send_event(win, text):
    ipc.send(win.pid, "ev\t" .. to_string(win.id) .. "\t" .. text)

func remote_open(src, q):
    let w = to_int(q[2])
    let h = to_int(q[3])
    if w < 8 or h < 8 or w > 2000 or h > 2000:
        return "err\tEINVAL\tbad window size"
    let seg = ipc.shm_open(to_int(q[4]))
    if seg[1] < w * h * 4:
        return "err\tEINVAL\tbuffer too small"
    let win = {id: next_win, pid: src, w: w, h: h, canvas: gfx.canvas(w, h, 0x000000), seg: seg, view: nil, frame: nil}
    next_win += 1
    ipc.shm_to_canvas(seg[0], win.canvas)
    win.view = RemoteView(win)
    let p = place()
    win.frame = desk.open_window(q[1], p[0], p[1], w + 12, h + 34, win.view)
    func closed(f):
        send_event(win, "close")
        ipc.shm_close(seg[0])
        remote[to_string(win.id)] = nil
        log("window " .. to_string(win.id) .. " closed")
        return true
    win.frame.on_close = closed
    remote[to_string(win.id)] = win
    log("window " .. to_string(win.id) .. " of pid " .. to_string(src) .. " opened (" .. to_string(w) .. "x" .. to_string(h) .. ")")
    return "ok\t" .. to_string(win.id)

# one message from a client; the answer for requests that have one
func serve(src, text):
    let q = text.split("\t")
    if q[0] == "open":
        ipc.send(src, remote_open(src, q))
        return nil
    let win = remote[q[1]] if len(q) > 1 and q[1] in remote else nil
    if win == nil or win.pid != src:
        return nil
    if q[0] == "present":
        ipc.shm_to_canvas(win.seg[0], win.canvas)
        win.view.dirty()
    elif q[0] == "title":
        win.frame.title = q[2]
        desk.redraw()
    elif q[0] == "close":
        ipc.shm_close(win.seg[0])
        remote[q[1]] = nil
        desk.close_frame(win.frame)

func pump_clients():
    while true:
        let m = ipc.recv_from(false)
        if m == nil:
            return nil
        serve(m[0], m[1])

func open_demo(ic = nil):
    log("open Demo")
    psys.spawn("gdemo")
desk.add_icon("Demo", 20, 422, open_demo)
ipc.register("gui")
desk.set_clock(rtc.clock_text())
func update_clock(a):
    desk.set_clock(rtc.clock_text())
desk.every(5000, update_clock)

# ---- the pointer ---------------------------------------------------------------------------------
let cursor_cache = {}
let cursor_now = ""
let cursor_seg = nil
func set_pointer(name):
    if name == cursor_now:
        return nil
    cursor_now = name
    if not (name in cursor_cache):
        let c = gfx.canvas(24, 24, 0xFF00FF)
        gui.draw_cursor(c, name, 8, 8)
        cursor_cache[name] = c
    if gpu != nil:
        if cursor_seg == nil:
            cursor_seg = ipc.shm_create(24 * 24 * 4)
        ipc.canvas_to_shm(cursor_cache[name], cursor_seg[1])
        ipc.send(gpu, "cursor_image\t" .. to_string(cursor_seg[0]) .. "\t8\t8")
    else:
        gdev.cursor_image(cursor_cache[name], 8, 8)

func cursor_to(x, y):
    if gpu != nil:
        ipc.send(gpu, "cursor_move\t" .. to_string(x) .. "\t" .. to_string(y))
    else:
        gdev.cursor_move(x, y)

func show(rx, ry, rw, rh):
    gdev.present(desk.canvas, 0, 0, rx, ry, rw, rh)
    if gpu != nil:
        ipc.send(gpu, "flush\t" .. to_string(rx) .. "\t" .. to_string(ry) .. "\t" .. to_string(rw) .. "\t" .. to_string(rh))

# ---- the input driver: events arrive as messages (inputd is interrupt driven), the pointer position is kept here ----
let input = uinput.Input(W, H)
let input_pid = nil
for i in range(100):
    input_pid = ipc.lookup("input")
    if input_pid != nil:
        break
    psys.sleep_ms(20)
if input_pid == nil:
    log("no input driver")
else:
    io.flush()
    ipc.send(input_pid, "sub\t" .. to_string(W) .. "\t" .. to_string(H))
    while true:
        let m = ipc.recv_from()
        if m[0] == input_pid:
            let f = m[1].split("\t")
            input.mx = to_int(f[1])
            input.my = to_int(f[2])
            break

# ---- main loop ----------------------------------------------------------------------------------
# The process sleeps in ipc.recv_from() until something happens: an input event from inputd, a request from a client, or the 20 ms frame tick (a timer
# interrupt of the kernel). No device is polled.
desk.draw()
show(0, 0, W, H)
set_pointer("arrow")
cursor_to(input.mx, input.my)
log("ready after " .. to_string(psys.ms()) .. " ms")

let last = psys.ms()
let frames = 0
let evs = []
while desk.running:
    let wait = 20 - (psys.ms() - last)
    if wait < 1:
        wait = 1
    io.flush()
    let m = ipc.recv_from(true, wait)
    while m != nil:
        if m[0] == input_pid and m[1].starts_with("in\t"):
            for e in input.feed(m[1].slice(3, len(m[1]))):
                evs.append(e)
        else:
            serve(m[0], m[1])
        m = ipc.recv_from(false)
    let moved = false
    for ev in evs:
        if ev.type == "mouse_move":
            moved = true
        desk.dispatch(ev)
    evs = []
    desk.pump()
    let now = psys.ms()
    if now - last >= 20:
        desk.dispatch(gui.tick(now - last))
        desk.pump()
        last = now
    if desk.needs_draw:
        desk.draw()
        let r = desk.last_rect
        show(r[0], r[1], r[2], r[3])
        frames += 1
    if moved:
        cursor_to(input.mx, input.my)
        set_pointer(desk.cursor_name())
log("stopped after " .. to_string(frames) .. " frames")
