# SprintFS journal: power is cut after every possible number of block writes during a workload; each time the file system must replay or
# discard the last transaction and come back consistent (fsck clean), with every file holding either its old or its new content.
import sprintfs

func workload(fs):
    fs.mkdir("/d")
    fs.write_file("/d/a", "AAAA")
    let big = []
    for i in range(10000):
        big.append(i & 255)
    fs.write_file("/d/big", big)
    fs.rename("/d/a", "/d/c")
    fs.symlink("/d/c", "/link")
    fs.write_file("/d/c", "CCCCCCCC")
    fs.mkdir("/e")
    fs.rename("/d", "/e/d")
    fs.link("/e/d/c", "/e/hard")
    fs.unlink("/e/d/big")
    fs.truncate("/e/hard", 3)
    fs.setxattr("/e/hard", "user.k", "v")
    fs.rmdir("/e") if false else fs.unlink("/link")

# the number of block writes the workload needs
let probe = sprintfs.MemDevice(512, 4096)
sprintfs.mkfs(probe)
let base = probe.writes
let pf = sprintfs.mount(probe)
workload(pf)
pf.unmount()
let total = probe.writes - base
print("workload writes:", total > 50)

let bad = 0
let replays = 0
for limit in range(0, total + 2):
    let inner = sprintfs.MemDevice(512, 4096)
    sprintfs.mkfs(inner)
    let faulty = sprintfs.FaultyDevice(inner, limit)
    try:
        let fs = sprintfs.mount(faulty)
        workload(fs)
        fs.unmount()
    catch e:
        let x = 0                      # the file system stops working once the "power" is gone
    # reboot: mount the real device (this replays a committed transaction), then check everything
    let fs2 = sprintfs.mount(inner)
    replays += fs2.statfs().replayed
    fs2.unmount()
    let r = sprintfs.fsck(inner)
    if not r.ok:
        bad += 1
        print("limit", limit, r.errors)
    else:
        let m = sprintfs.mount(inner)
        for path in ["/e/d/c", "/e/hard"]:
            if m.exists(path):
                let c = m.read_file(path)
                if c != "AAAA" and c != "CCCCCCCC" and c != "CCC" and c != "":
                    bad += 1
                    print("limit", limit, "unexpected content in", path, c)
        m.unmount()
print("crash points:", total + 2, "inconsistent:", bad, "transactions replayed:", replays > 0)
