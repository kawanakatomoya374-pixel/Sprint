# exptest: runs the file manager's logic (stdlib/explorer.sp) on the real file system server with synthetic events and no window, and reports what it did
# (the QEMU test os-explorer-test runs this as the init program and then checks the disk from the host).
import psys as sys
import fsclient
import explorer
import gfx
import sslcore
import io

func say(s):
    print("exptest: " .. s)
    io.flush()

let srv = sys.spawn("fsd")
let fs = fsclient.connect()
fs.mkdir("/docs")
fs.write_file("/docs/note.txt", "a text file\n")
let bin = []
for i in range(70000):
    bin.append((i * 31 + (i >> 8)) & 255)
let binary = sslcore.concat([bin])
fs.write_bytes("/docs/data.bin", binary, 0, true)
say("binary written, " .. to_string(fs.stat("/docs/data.bin").size) .. " bytes")
say("binary read back equal: " .. to_string(sslcore.eq(fs.read_bytes("/docs/data.bin"), binary)))
let canvas = gfx.canvas(720, 460, 0)
let ex = explorer.Explorer(canvas, fs, sys.ms)
func key(k):
    ex.event({type: "key", key: k})
func text(s):
    ex.event({type: "text", text: s})
say("root: " .. ex.entries.map(e => e.name).join(","))
ex.goto("/docs")
ex.select_only("data.bin")
key("Ctrl+C")
ex.goto("/")
key("Ctrl+Shift+N")
text("Backup")
key("Enter")
ex.goto("/Backup")
key("Ctrl+V")
say("pasted: " .. ex.entries.map(e => e.name).join(","))
ex.goto("/docs")
ex.select_only("note.txt")
key("Ctrl+X")
ex.goto("/Backup")
key("Ctrl+V")
key("F2")
text("moved.txt")
key("Enter")
say("backup: " .. ex.entries.map(e => e.name).join(","))
say("copy equal: " .. to_string(sslcore.eq(fs.read_bytes("/Backup/data.bin"), binary)))
ex.goto("/")
ex.select_only("docs")
key("Delete")
key("Enter")
say("root after delete: " .. ex.entries.map(e => e.name).join(","))
say("status: " .. to_string(fs.statfs().blocks > 0))
fs.sync()
say("done")
fs.quit()
sys.wait(srv)
