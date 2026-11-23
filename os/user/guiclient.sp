# guiclient: windows served by the GUI server (guid). A program that is not the GUI server draws into a canvas of its own, in a buffer it shares with
# guid, and asks guid to show it; guid frames it, moves it, stacks it and sends back the pointer and keyboard events for it as messages.
#
#   import guiclient
#   let conn = guiclient.connect()
#   let win = conn.open_window("Hello", 200, 120)       # win.canvas is a gfx canvas of that size
#   win.canvas.text(10, 10, "hi", 0xffffff)
#   win.present()
#   for ev in win.poll():                               # {type: "ptr", kind: "down" | "move" | "up", x, y, button} | {type: "key", key} | {type: "text", text} | {type: "close"}
#       ...
# Messages from the server arrive on the process's ordinary message queue; poll() and the waits below read it, so the program should not receive other
# messages itself. The server is found by the name "gui".
import io
import ipc
import gfx
import psys

export class Window:
    let conn = nil
    let id = 0
    let canvas = nil
    let seg = nil
    let w = 0
    let h = 0
    func init(self, conn, id, canvas, seg, w, h):
        self.conn = conn
        self.id = id
        self.canvas = canvas
        self.seg = seg
        self.w = w
        self.h = h
    # show what has been drawn
    func present(self):
        ipc.canvas_to_shm(self.canvas, self.seg[1])
        self.conn.send("present\t" .. to_string(self.id))
    func set_title(self, title):
        self.conn.send("title\t" .. to_string(self.id) .. "\t" .. title)
    # the events waiting for this window (without blocking)
    func poll(self):
        self.conn.pump(false)
        let mine = []
        let rest = []
        for e in self.conn.events:
            if e.win == self.id:
                mine.append(e)
            else:
                rest.append(e)
        self.conn.events = rest
        return mine
    func close(self):
        self.conn.send("close\t" .. to_string(self.id))
        ipc.shm_close(self.seg[1])

export class Conn:
    let server = 0
    let events = []
    func init(self, server):
        self.server = server
        self.events = []
    func send(self, text):
        io.flush()
        ipc.send(self.server, text)
    func decode(self, msg):
        let f = msg.split("\t")
        if f[0] != "ev":
            return f
        let e = {win: to_int(f[1]), type: f[2]}
        if e.type == "ptr":
            e.kind = f[3]
            e.x = to_int(f[4])
            e.y = to_int(f[5])
            e.button = to_int(f[6])
        elif e.type == "key":
            e.key = f[3]
        elif e.type == "text":
            e.text = f[3]
        self.events.append(e)
        return nil
    # reads waiting messages (all of them, or, with block = true, until a reply arrives); returns the reply fields or nil
    func pump(self, block):
        while true:
            let m = ipc.recv_from(block)
            if m == nil:
                return nil
            if m[0] != self.server:
                continue
            let r = self.decode(m[1])
            if r != nil:
                return r
            if block:
                continue
    func open_window(self, title, w, h):
        let seg = ipc.shm_create(w * h * 4)
        let canvas = gfx.canvas(w, h, 0x000000)
        self.send("open\t" .. title .. "\t" .. to_string(w) .. "\t" .. to_string(h) .. "\t" .. to_string(seg[0]))
        let r = self.pump(true)
        if r[0] != "ok":
            throw error("OSError", "guid: " .. r.join(" "))
        return Window(self, to_int(r[1]), canvas, [seg[0], seg[1], seg[2]], w, h)

# waits (up to timeout_ms) for the GUI server to register, then connects
export func connect(timeout_ms = 10000):
    let t0 = psys.ms()
    while true:
        let pid = ipc.lookup("gui")
        if pid != nil:
            return Conn(pid)
        if psys.ms() - t0 > timeout_ms:
            throw error("OSError", "no GUI server")
        psys.sleep_ms(10)
