# filemgr: the file manager as a GUI client process: a window from guid (guiclient) around stdlib/explorer.sp, working on the file system server (fsclient).
# Started from the desktop's Explorer icon.
import guiclient
import fsclient
import explorer
import psys
import io

func log(s):
    print("[explorer] " .. s)
    io.flush()

# what the window shows when there is no file system disk
class NoDisk:
    func fail(self):
        throw error("ENODEV", "no file system volume (attach a SprintFS disk)")
    func listdir(self, p):
        self.fail()
    func stat(self, p):
        self.fail()
    func exists(self, p):
        return false
    func mkdir(self, p):
        self.fail()
    func unlink(self, p):
        self.fail()
    func rmdir(self, p):
        self.fail()
    func rename(self, a, b):
        self.fail()
    func read_bytes(self, p, o, n):
        self.fail()
    func write_bytes(self, p, d, o, t):
        self.fail()
    func statfs(self):
        self.fail()

let fs = nil
try:
    fs = fsclient.connect(3000)
catch e:
    log("no file system server: " .. to_string(e))
    fs = NoDisk()
let conn = guiclient.connect()
let win = conn.open_window("File Explorer", 720, 460)
let ex = explorer.Explorer(win.canvas, fs, psys.ms)
func opened(path):
    log("open " .. path)
    ex.status = "Opened " .. path
ex.on_open = opened
win.present()
log("window open, " .. to_string(len(ex.entries)) .. " entries in " .. ex.cwd)
let last = ex.cwd
let running = true
while running:
    let evs = win.poll()
    let changed = false
    for e in evs:
        if e.type == "close":
            running = false
        elif ex.event(e):
            changed = true
    if ex.cwd != last:
        last = ex.cwd
        log("cwd " .. ex.cwd .. ", " .. to_string(len(ex.entries)) .. " entries")
    if changed:
        win.present()
    if len(evs) == 0:
        psys.sleep_ms(10)
win.close()
log("bye")
