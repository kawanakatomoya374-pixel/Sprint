# window: the platform layer between a gui.App and a display. A Backend owns one window: it delivers
# input events (the same dicts gui.mouse_move() etc. build), shows finished frames and receives the
# mouse-pointer shape. Backends are looked up by name; "headless" (an in-memory display that scripts
# feed with events and that keeps every presented frame's hash) is always present. "x11" is a native
# window on Linux/BSD (needs --allow-window and an X server; libX11 is loaded at run time). Other native backends
# (Win32, Cocoa, framebuffer) register themselves with register().
#
#   import window
#   let win = window.open(320, 200, "demo")
#   win.feed(gui.mouse_down(10, 10))
#   window.run(app, win)
import gfx
import gui
import time
import _x11

# Interface every backend implements.
export class Backend:
    let name = "none"
    let width = 0
    let height = 0
    let title = ""
    let closed = false
    # true for a backend backed by a host window: run() keeps waiting for events instead of stopping when none are queued
    let live = false
    func init(self):
        self.name = "none"
    func open(self, w, h, title):
        self.width = w
        self.height = h
        self.title = title
    # events that arrived since the last call (oldest first)
    func poll(self):
        return []
    # show a finished frame (a gfx canvas of the window size)
    func present(self, canvas):
        return nil
    # the host pointer shape: "arrow", "ibeam", "hand", ... or "none" when the app draws its own
    func set_cursor(self, name):
        return nil
    func get_clipboard(self):
        return ""
    func set_clipboard(self, s):
        return nil
    func set_title(self, s):
        self.title = s
    func close(self):
        self.closed = true

# An in-memory display: deterministic, needs no host support.
export class Headless extends Backend:
    let pending = []
    let frames = 0
    let hashes = []
    let last = nil
    let cursor = "arrow"
    let clip = ""
    let keep = 16
    override func init(self):
        self.name = "headless"
    func feed(self, ev):
        self.pending.append(ev)
        return self
    func feed_all(self, evs):
        for ev in evs:
            self.pending.append(ev)
        return self
    override func poll(self):
        let out = self.pending
        self.pending = []
        return out
    override func present(self, canvas):
        self.frames += 1
        self.last = canvas
        self.hashes.append(canvas.hash())
        if len(self.hashes) > self.keep:
            self.hashes.remove_at(0)
    override func set_cursor(self, name):
        self.cursor = name
    override func get_clipboard(self):
        return self.clip
    override func set_clipboard(self, s):
        self.clip = s
    func screenshot(self, path):
        self.last.save_png(path)

# A native X11 window (Linux/BSD). Needs --allow-window and a reachable X server (DISPLAY); libX11 is loaded at run
# time. poll() waits up to `wait_ms` for input and adds a "tick" event about every `tick_ms` so animations advance.
export class X11 extends Backend:
    let win = nil
    let wait_ms = 16
    let tick_ms = 16
    let last = 0.0
    override func init(self):
        self.name = "x11"
        self.live = true
    override func open(self, w, h, title):
        self.width = w
        self.height = h
        self.title = title
        self.win = _x11.open(w, h, title)
        self.last = time.monotonic()
    override func poll(self):
        if self.closed:
            return []
        let evs = self.win.poll(self.wait_ms)
        let now = time.monotonic()
        let dt = (now - self.last) * 1000.0
        if dt >= self.tick_ms:
            self.last = now
            evs.append(gui.tick(to_int(dt)))
        return evs
    override func present(self, canvas):
        self.win.present(canvas)
    override func set_cursor(self, name):
        self.win.set_cursor(name)
    override func get_clipboard(self):
        return self.win.get_clipboard()
    override func set_clipboard(self, s):
        self.win.set_clipboard(s)
    override func set_title(self, s):
        self.title = s
        self.win.set_title(s)
    override func close(self):
        if not self.closed:
            self.win.close()
        self.closed = true

const FACTORIES = {headless: () => Headless(), x11: () => X11()}

# register(name, factory): factory() returns a Backend. Replaces an earlier backend of that name.
export func register(name, factory):
    FACTORIES[name] = factory

export func backends():
    let out = []
    for k, v in FACTORIES:
        out.append(k)
    out.sort()
    return out

export func available(name):
    return name in FACTORIES

# Open a window of w x h pixels on the named backend ("headless" unless a native one is registered).
export func open(w, h, title = "", backend = "headless"):
    if not (backend in FACTORIES):
        throw error("ValueError", "window backend '" .. backend .. "' is not available in this build (have: " .. backends().join(", ") .. ")")
    let b = FACTORIES[backend]()
    b.open(w, h, title)
    return b

# Drive `app` from the window until it quits, the window closes, or max_frames frames were shown
# (max_frames < 0: no limit; when the backend has no more events the loop ends too unless `idle`
# is given, which is called each time the event queue ran dry and returns false to stop).
export func run(app, win, max_frames = -1, idle = nil):
    let shown = 0
    app.show_cursor = win.name == "headless" or app.show_cursor
    while app.running and not win.closed:
        let evs = win.poll()
        if len(evs) == 0 and not win.live:
            if idle == nil or not idle(app, win):
                break
        for ev in evs:
            if ev.type == "quit":
                win.close()
                break
            app.dispatch(ev)
            app.pump()
        if app.needs_draw:
            app.draw()
            win.present(app.canvas)
            win.set_cursor("none" if app.show_cursor else app.cursor_name())
            shown += 1
            if max_frames >= 0 and shown >= max_frames:
                break
    return shown
