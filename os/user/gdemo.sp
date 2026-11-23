# gdemo: a GUI client process. Opens a window through guid, draws into it, and reacts to the pointer and keyboard events guid sends.
import guiclient
import psys
import io

func log(s):
    print("[gdemo] " .. s)
    io.flush()

let conn = guiclient.connect()
let win = conn.open_window("Demo", 220, 130)
let c = win.canvas
let clicks = 0
let typed = ""
func paint():
    c.clear(0x20b050)
    c.fill_rect(0, 0, 220, 20, 0x105028)
    c.text(8, 5, "client process " .. to_string(psys.pid()), 0xffffff)
    c.text(8, 30, "clicks: " .. to_string(clicks), 0xffffff)
    c.text(8, 46, "typed: " .. typed, 0xffffff)
paint()
win.present()
log("window open")
let running = true
while running:
    let evs = win.poll()
    let dirty = false
    for e in evs:
        if e.type == "ptr" and e.kind == "down":
            clicks += 1
            c.fill_circle(e.x, e.y, 6, 0xff3030)
            log("pointer down at " .. to_string(e.x) .. "," .. to_string(e.y))
            dirty = true
        elif e.type == "key":
            log("key " .. e.key)
        elif e.type == "text":
            typed = typed .. e.text
            log("text " .. e.text)
            paint()
            dirty = true
        elif e.type == "close":
            log("close requested")
            running = false
    if dirty:
        win.present()
    if len(evs) == 0:
        psys.sleep_ms(10)
win.close()
log("bye")
