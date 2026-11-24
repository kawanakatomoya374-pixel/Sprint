# SprintFS reads whole runs of blocks: compare random reads (inside runs, across extents, over holes, at the end) with a model kept in memory
import sprintfs
import typed

let dev = sprintfs.MemDevice(4096, 4096)
sprintfs.mkfs(dev, {})
let m = sprintfs.mount(dev)
let seed = 12345
func rnd(n):
    seed = (seed * 1103515245 + 12345) & 0x7fffffff
    return (seed >> 8) % n

let model = typed.u8(300000)
let f = m.open("/f", "w+")
# pieces written at scattered offsets leave holes between them
let top = 0
for r in range(12):
    let at = rnd(280000)
    let n = 1 + rnd(9000)
    if at + n > 300000:
        n = 300000 - at
    let d = typed.u8(n)
    for k in range(n):
        d[k] = (at + k + r) & 255
    f.seek(at)
    f.write(d)
    model.set_from(d, at)
    if at + n > top:
        top = at + n
f.close()
let g = m.open("/f", "r")
let bad = 0
for t in range(60):
    let off = rnd(top)
    let n = 1 + rnd(40000)
    g.seek(off)
    let got = g.read(n)
    let want = n if off + n <= top else top - off
    if len(got) != want:
        bad += 1
        continue
    for k in range(want):
        if got[k] != model[off + k]:
            bad += 1
            break
g.close()
print("random reads wrong:", bad)
m.unmount()
