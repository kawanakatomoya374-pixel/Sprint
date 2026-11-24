# packinstall: puts a C-OS app pack (a folder with linuxpack.manifest and its chunks, e.g. a clone of C-OS-APPS/apps/lua) into a SprintFS image, after checking the
# release signature, the size and SHA-256 of every chunk and the zlib streams. Links and executable bits are kept.
# usage: sprint run --allow-read=DIR --allow-write=DIR tools/packinstall.sp IMAGE PACKDIR [ROOT]
#   ROOT is the folder inside the image the pack's files go below (default "": the pack's own root, "/" for a Linux root file system)
import fs as host
import sprintfs
import cosapps
import sys

let a = sys.args
if len(a) < 2:
    print("usage: packinstall.sp IMAGE PACKDIR [ROOT]")
    sys.exit(2)
let image = a[0]
let packdir = a[1]
let root = a[2] if len(a) > 2 else ""
while packdir.ends_with("/") and len(packdir) > 1:
    packdir = packdir.slice(0, len(packdir) - 1)
let slash = 0
for i in range(len(packdir)):
    if packdir[i] == 47:
        slash = i
let base = packdir.slice(0, slash + 1) if slash > 0 else "./"
let name = packdir.slice(slash + 1)

class DirSource:
    func get(self, path):
        try:
            return host.read_bytes(base .. path)
        catch e:
            return nil

let dev = sprintfs.device_from_bytes(host.read_bytes(image), 4096)
let vol = sprintfs.mount(dev)
let sink = cosapps.VolumeSink(vol, root)
let pack = cosapps.install(DirSource(), name, sink, (done, total) => print("  chunk " .. to_string(done) .. " of " .. to_string(total)))
vol.unmount()
host.write_bytes(image, dev.to_bytes())
print("installed " .. pack.title .. " " .. pack.version .. ": " .. to_string(sink.count) .. " files, " .. to_string(sink.bytes) .. " bytes, " .. to_string(sink.links) .. " links")
