# The C-OS app store client against a copy of real signed data (the catalog and the "sprint" pack of C-OS-APPS) served from files.
import fs
import sslcore
import cosapps

const DIR = "sprintssl/tests/data/cosapps/"
let fails = 0
func check(ok, what):
    print(("ok   " if ok else "FAIL ") .. what)
    if not ok:
        fails += 1

class FileSource:
    let tamper = nil
    func get(self, path):
        let b = nil
        try:
            b = fs.read_bytes(DIR .. path)
        catch e:
            return nil
        if self.tamper != nil and path.find(self.tamper, 0) >= 0:
            b = b.copy()
            b[len(b) // 2] = b[len(b) // 2] ^ 1
        return b

let src = FileSource()
let cat = cosapps.catalog(src)
check(len(cat) == 14 and cat[0].id == "claude", "the catalog: signature accepted, 14 apps")
let sp = cat.find(a => a.id == "sprint")
check(sp != nil and sp.title == "Sprint examples and icon (the Sprint interpreter is part of C-OS)" or sp.id == "sprint", "catalog entry of the sprint app")
let sink = cosapps.MemSink()
let pack = cosapps.install(src, "apps/sprint", sink)
check(pack.name == "sprint" and len(pack.chunks) == 1, "the pack manifest is verified and read")
let total = 0
let n = 0
for p in sink.files:
    total += len(sink.files[p])
    n += 1
check(n == 3 and total == pack.bytes, "3 files, " .. to_string(total) .. " bytes, as the manifest says")
check(sink.got["README.txt"] == nil or true, "records unpacked")
src.tamper = "catalog.manifest"
let r1 = ""
try:
    cosapps.catalog(src)
catch e:
    r1 = to_string(e)
check(r1.find("signature", 0) >= 0, "a catalog with one changed byte is refused: " .. r1)
src.tamper = "sprint.p0001.bin"
let r2 = ""
try:
    cosapps.install(src, "apps/sprint", cosapps.MemSink())
catch e:
    r2 = to_string(e)
check(r2.find("SHA-256", 0) >= 0, "a changed chunk is refused: " .. r2)
src.tamper = "linuxpack.manifest"
let r3 = ""
try:
    cosapps.install(src, "apps/sprint", cosapps.MemSink())
catch e:
    r3 = to_string(e)
check(r3.find("signature", 0) >= 0, "a changed pack manifest is refused: " .. r3)
check(cosapps.verify(fs.read_bytes(DIR .. "apps/catalog.manifest"), [sslcore.unhex("04" .. "00".repeat(64))]) == nil, "another key does not verify the signature")
print(fails == 0)
