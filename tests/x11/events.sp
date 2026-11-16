import gfx
import window
import time
let win = window.open(320, 200, "evtest", "x11")
let c = gfx.canvas(320, 200, 0x336699)
c.fill_rect(20, 20, 100, 60, 0xffcc00)
win.present(c)
print("READY")
let t0 = time.monotonic()
while time.monotonic() - t0 < 6.0 and not win.closed:
    for ev in win.poll():
        if ev.type == "tick":
            continue
        print(ev)
        if ev.type == "quit" or (ev.type == "key" and ev.key == "ShiftTab"):
            win.close()
win.close()
print("DONE")
