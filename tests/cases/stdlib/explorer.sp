# the file manager (stdlib/explorer.sp) driven with synthetic events over a SprintFS volume in memory: navigation, selection, rename, new folder, copy / cut /
# paste, delete with confirmation, sorting, drag and drop, the address bar, a context menu
import sprintfs
import explorer
import gfx
import sslcore

let dev = sprintfs.MemDevice(2048, 4096)
sprintfs.mkfs(dev, {label: "t"})
let vol = sprintfs.mount(dev)
vol.mkdir("/docs")
vol.mkdir("/docs/sub")
vol.mkdir("/music")
vol.write_file("/readme.txt", "hello")
vol.write_file("/docs/a.txt", "alpha")
vol.write_file("/docs/b.sp", "print(1)")
vol.write_file("/docs/sub/deep.bin", "deep")
let big = []
for i in range(5000):
    big.append((i * 7) & 255)
let f = vol.create("/docs/blob.dat")
f.write(sslcore.concat([big]))
f.close()

let now = 1000
func clock():
    return now
let canvas = gfx.canvas(720, 460, 0)
let ex = explorer.Explorer(canvas, explorer.VolumeBackend(vol), clock)

func names():
    return ex.entries.map(e => e.name).join(",")
func ptr(kind, x, y, button = 1):
    return ex.event({type: "ptr", kind: kind, x: x, y: y, button: button})
func key(k):
    return ex.event({type: "key", key: k})
func text(s):
    return ex.event({type: "text", text: s})
func click(x, y):
    ptr("down", x, y)
    ptr("up", x, y)
func row_y(i):
    return explorer.ROW_Y0 + i * 20 + 8

print("start", ex.cwd, names())
print(ex.entries.map(e => e.kind).join(","))
# select the second row (docs is first of the folders: docs, music), double click to enter
click(300, row_y(0))
print("selected", ex.selected_names().join(","))
now += 100
click(300, row_y(0))
print("entered", ex.cwd, names())
key("Alt+Left")
print("back", ex.cwd)
key("Alt+Right")
print("forward", ex.cwd)
key("Backspace")
print("up", ex.cwd)
# keyboard selection
key("Down")
key("Down")
print("down down", ex.selected_names().join(","))
key("Shift+Down")
print("shift down", ex.selected_names().join(","))
key("Ctrl+A")
print("select all", len(ex.selected_names()))
key("Escape")
# new folder, type a name, Enter
key("Ctrl+Shift+N")
print("renaming", ex.edit != nil and ex.edit.kind, ex.edit.text)
text("Projects")
key("Enter")
print("after new folder", names())
print("exists", vol.exists("/Projects"))
# rename with F2
key("F2")
text("Work")
key("Enter")
print("renamed", vol.exists("/Work"), vol.exists("/Projects"))
# duplicate name refused
key("F2")
text("docs")
key("Enter")
print("duplicate: modal", ex.modal != nil and ex.modal.kind)
key("Enter")
# copy docs into Work
ex.select_only("docs")
key("Ctrl+C")
ex.goto("/Work")
key("Ctrl+V")
print("pasted", names(), vol.exists("/Work/docs/sub/deep.bin"))
print("copy equal", len(vol.read_bytes("/Work/docs/blob.dat")), sslcore.eq(vol.read_bytes("/Work/docs/blob.dat"), vol.read_bytes("/docs/blob.dat")))
# paste again: gets a new name
key("Ctrl+V")
print("pasted twice", names())
# cut and paste elsewhere
ex.select_only("docs - Copy")
key("Ctrl+X")
ex.goto("/music")
key("Ctrl+V")
print("moved", names(), vol.exists("/Work/docs - Copy"))
# delete with confirmation
ex.select_only("docs - Copy")
key("Delete")
print("confirm", ex.modal != nil and ex.modal.kind)
key("Escape")
print("still there", vol.exists("/music/docs - Copy"))
key("Delete")
key("Enter")
print("deleted", vol.exists("/music/docs - Copy"), names())
# sorting
ex.goto("/docs")
print("by name", names())
ptr("down", 200 + 450, 70 + 11)
ptr("up", 200 + 450, 70 + 11)
print("by size", ex.sort_key, names())
ptr("down", 200 + 450, 70 + 11)
ptr("up", 200 + 450, 70 + 11)
print("by size desc", names())
# the address bar
click(300, 34 + 13)
print("address edit", ex.edit != nil and ex.edit.kind)
text("/Work/docs")
key("Enter")
print("address goto", ex.cwd)
click(300, 34 + 13)
text("/nowhere")
key("Enter")
print("bad address", ex.cwd, ex.modal != nil)
key("Enter")
# type-ahead
ex.goto("/docs")
text("b")
print("jump", ex.selected_names().join(","))
# context menu on an item and on the empty area
ex.select_only("a.txt")
ptr("down", 300, row_y(0), 3)
print("menu", ex.menu != nil and len(ex.menu.items))
key("Escape")
ptr("down", 400, 400, 3)
print("menu empty", ex.menu != nil and ex.menu.items[0][0])
key("Escape")
# drag a file onto a folder
ex.goto("/docs")
ex.select_only("a.txt")
let ai = 0
for i in range(len(ex.entries)):
    if ex.entries[i].name == "a.txt":
        ai = i
let si = 0
for i in range(len(ex.entries)):
    if ex.entries[i].name == "sub":
        si = i
ptr("down", 300, row_y(ai))
ptr("move", 320, row_y(ai) + 10)
ptr("move", 320, row_y(si))
ptr("up", 320, row_y(si))
print("dragged", vol.exists("/docs/sub/a.txt"), vol.exists("/docs/a.txt"))
# the tree
click(14, 64 + 9)
print("tree toggle", ex.tree_open["/"])
print("canvas drawn", canvas.hash() > 0)
print("done", len(ex.entries))
