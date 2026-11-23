# gputest: starts the GPU driver server and draws test bands through it (the QEMU test os-gpu-test runs this as the init program).
import psys as sys
import ipc
import uio
import io
import gfx

func say(s):
    print("[gputest] " .. s)
    io.flush()

let gpud = sys.spawn("gpud")
let pid = nil
for i in range(200):
    pid = ipc.lookup("gpu")
    if pid != nil:
        break
    sys.sleep_ms(10)
ipc.send(pid, "info")
let r = ipc.recv().split("\t")
if r[0] != "ok":
    say("no gpu: " .. r.join(" "))
    ipc.send(pid, "quit")
    sys.wait(gpud)
    sys.exit(1)
let w = to_int(r[1])
let h = to_int(r[2])
let seg = ipc.shm_open(to_int(r[4]))
say("screen " .. to_string(w) .. "x" .. to_string(h) .. " pitch " .. r[3])
let colors = [0xff0000, 0x00ff00, 0x0000ff, 0xffff00]
for y in range(h):
    let c = colors[y * 4 // h]
    for x in range(w):
        uio.poke32(seg[0] + 4 * (y * w + x), c)
ipc.send(pid, "flush\t0\t0\t" .. to_string(w) .. "\t" .. to_string(h))
# a pointer image: a white arrow-ish block with a transparent corner
let cur = gfx.canvas(24, 24, 0xFF00FF)
cur.fill_rect(0, 0, 12, 18, 0xffffff)
cur.rect(0, 0, 12, 18, 0x000000)
let cs = ipc.shm_create(24 * 24 * 4)
ipc.canvas_to_shm(cur, cs[1])
ipc.send(pid, "cursor_image\t" .. to_string(cs[0]) .. "\t0\t0")
say("cursor image: " .. ipc.recv())
ipc.send(pid, "cursor_move\t300\t200")
# a rectangle flush after a partial update
for y in range(100, 140):
    for x in range(500, 700):
        uio.poke32(seg[0] + 4 * (y * w + x), 0xffffff)
ipc.send(pid, "flush\t500\t100\t200\t40")
say("drawn")
sys.sleep_ms(4000)
ipc.send(pid, "quit")
sys.wait(gpud)
say("done")
