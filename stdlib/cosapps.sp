# cosapps: the client of the C-OS app store (github.com/kawanakatomoya374-pixel/C-OS-APPS, served by GitHub Pages): verify and read the signed catalog and
# pack manifests, download the zlib chunks, check them, and hand the files to a sink.
#
#   import cosapps
#   let src = cosapps.HttpsSource("kawanakatomoya374-pixel.github.io", "/C-OS-APPS/", connect_fn, roots, now)   # connect_fn() -> a transport (see sprintssl)
#   let cat = cosapps.catalog(src)                       # [{id, title, version, download, installed, ...}, ...]; throws error("ECOSAPPS", why) when the signature is wrong
#   let sink = cosapps.MemSink()
#   let pack = cosapps.install(src, "apps/lua", sink)    # downloads, verifies (signature, SHA-256 of every chunk, sizes), unpacks
#   sink.files["usr/bin/lua"]                            # typed.u8
#
# Formats (tools/linux_pack.py and tools/sign_linuxpack.py of C-OS): a manifest is text, then a line "--SIG--" and 128 hex digits, an ECDSA P-256 signature
# (r || s) over the SHA-256 of the text before the marker, made with the C-OS release key. A pack manifest starts with "COSLP 1", the catalog with "COSAPPS 1".
# A chunk is a zlib stream of records: u16 path length | path | u8 kind (0) | u64 file size | u64 offset | u32 length | data. The last record, ".manifest",
# lists links ("L<TAB>path<TAB>target") and executable files ("X<TAB>path").
import sslcore
import sslx509 as x509
import sprintssl
import typed

# the C-OS release key (the key the installer in C-OS trusts) and the other two public keys the C-OS project gave for its release signing
const KEYS_PEM = """-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE6RNjR1KRqz9QT6L4fxJ3yPJWZKSo
SCGj6rbxbm5GrVX3f8uZYpCFYY1fRgyKWCJuvR1Qcq87i7+IW1Q2amR+pA==
-----END PUBLIC KEY-----
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEccaGx3Aoq42pnTO8euoQcv1n8MEy
or2LohR+mMcqmyCexMAUkzRYmSWHWcZMKAq9c8mz32a5ftpmlQb+nqCVBg==
-----END PUBLIC KEY-----
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE37cPUBMM9OpxP0thTuSf8MXKZe/I
CDelbyb5xHd03JL7Qo9M3HL4JNrnWP064ijt7uYGt8P+jsotEONNya9GIA==
-----END PUBLIC KEY-----
"""

func fail(msg):
    throw error("ECOSAPPS", msg)

let release_keys = nil
export func keys():
    if release_keys == nil:
        release_keys = []
        let pos = 0
        while true:
            let a = KEYS_PEM.find("-----BEGIN PUBLIC KEY-----", pos)
            if a < 0:
                break
            let b = KEYS_PEM.find("-----END PUBLIC KEY-----", a)
            let der = x509.b64decode(KEYS_PEM.slice(a + 26, b))
            release_keys.append(der.slice(len(der) - 65))       # the SubjectPublicKeyInfo ends with the uncompressed point 04 || X || Y
            pos = b + 24
    return release_keys

func find_marker(b, marker):
    let n = len(marker)
    for i in range(len(b) - n + 1):
        let ok = true
        for j in range(n):
            if b[i + j] != marker[j]:
                ok = false
                break
        if ok:
            return i
    return -1

# the text of a signed manifest if the signature is a valid release signature, else nil
export func verify(manifest, extra_keys = nil):
    let at = find_marker(manifest, sslcore.from_str("--SIG--\n"))
    if at < 0:
        return nil
    let hexsig = sslcore.to_str(manifest.slice(at + 8)).trim()
    if len(hexsig) != 128:
        return nil
    let sig = nil
    try:
        sig = sslcore.unhex(hexsig)
    catch e:
        return nil
    let body = manifest.slice(0, at)
    let h = sslcore.hash(256, body)
    let all = keys() if extra_keys == nil else extra_keys
    for k in all:
        if sslcore.ecdsa_verify(256, k, h, sig.slice(0, 32), sig.slice(32, 64)):
            return sslcore.to_str(body)
    return nil

# "key=value key=value ..." after the first word of a line
func fields(line):
    let out = {}
    let parts = line.split(" ")
    for i in range(1, len(parts)):
        let k = parts[i].find("=", 0)
        if k > 0:
            out[parts[i].slice(0, k)] = parts[i].slice(k + 1)
    return out

func nice(s):
    return s.replace("_", " ")

export func parse_catalog(text):
    let lines = text.split("\n")
    if len(lines) == 0 or lines[0] != "COSAPPS 1":
        fail("not a catalog")
    let apps = []
    for l in lines:
        if l.starts_with("app "):
            let f = fields(l)
            f.title = nice(f.title ?? f.id)
            f.desc = nice(f.desc ?? "")
            f.download = to_int(f.download ?? "0")
            f.installed = to_int(f.installed ?? "0")
            apps.append(f)
    return apps

export func parse_pack(text):
    let lines = text.split("\n")
    if len(lines) == 0 or lines[0] != "COSLP 1":
        fail("not a pack manifest")
    let pack = nil
    let chunks = []
    for l in lines:
        if l.starts_with("pack "):
            pack = fields(l)
        elif l.starts_with("chunk "):
            let f = fields(l)
            f.size = to_int(f.size)
            f.raw = to_int(f.raw)
            chunks.append(f)
    if pack == nil:
        fail("a pack manifest without a pack line")
    pack.chunks = chunks
    pack.title = nice(pack.title ?? pack.name)
    pack.bytes = to_int(pack.bytes ?? "0")
    pack.download = to_int(pack.download ?? "0")
    return pack

# ---- sources ----
# a source gives the bytes of a path (relative to the store's base) or nil
export class HttpsSource:
    let host = ""
    let base = "/"
    let connect_fn = nil
    let roots = nil
    let now = nil
    let timeout = 20000
    func init(self, host, base, connect_fn, roots, now):
        self.host = host
        self.base = base
        self.connect_fn = connect_fn
        self.roots = roots
        self.now = now
    func get(self, path):
        let t = self.connect_fn()
        let conn = sprintssl.connect(t, self.host, self.roots, self.now)
        let r = sprintssl.http_get(conn, self.host, self.base .. path, self.timeout)
        conn.close()
        try:
            t.close()
        catch e:
            pass
        if r.status != 200:
            return nil
        return r.body

# ---- sinks ----
# keeps every file in memory (a file cut into pieces is put together by offset); also records links and the executable files
export class MemSink:
    let files = nil
    let sizes = nil
    let got = nil
    let links = nil
    let exec = nil
    func init(self):
        self.files = {}
        self.sizes = {}
        self.got = {}
        self.links = {}
        self.exec = {}
    func file(self, path, size, offset, data):
        let buf = self.files[path]
        if buf == nil:
            buf = typed.u8(size)
            self.files[path] = buf
            self.sizes[path] = size
            self.got[path] = 0
        buf.set_from(data, offset)
        self.got[path] += len(data)
    func link(self, path, target):
        self.links[path] = target
    func executable(self, path):
        self.exec[path] = true

# writes the files straight to a file system (an explorer-style backend: exists, mkdir, write_bytes) below `root`, creating the folders; links and executable bits
# are kept in the lists `links` and `exec` (the file system has neither symbolic links nor modes here)
export class BackendSink:
    let fs = nil
    let root = ""
    let links = nil
    let exec = nil
    let made = nil
    let count = 0
    let bytes = 0
    func init(self, fs, root = ""):
        self.fs = fs
        self.root = root
        self.links = {}
        self.exec = {}
        self.made = {}
    func ensure_dir(self, path):
        if path == "" or path == "/" or self.made[path]:
            return nil
        let i = len(path) - 1
        while i > 0 and path[i] != 47:
            i -= 1
        if i > 0:
            self.ensure_dir(path.slice(0, i))
        if not self.fs.exists(path):
            self.fs.mkdir(path)
        self.made[path] = true
    func file(self, path, size, offset, data):
        let full = self.root .. "/" .. path
        let i = len(full) - 1
        while i > 0 and full[i] != 47:
            i -= 1
        self.ensure_dir(full.slice(0, i))
        if offset == 0:
            self.count += 1
        self.fs.write_bytes(full, data, offset, offset == 0)
        self.bytes += len(data)
    func link(self, path, target):
        self.links[path] = target
    func executable(self, path):
        self.exec[path] = true

export func catalog(src):
    let m = src.get("apps/catalog.manifest")
    if m == nil:
        fail("the catalog could not be downloaded")
    let body = verify(m)
    if body == nil:
        fail("the catalog's signature is not valid")
    return parse_catalog(body)

func u16(b, o):
    return b[o] | (b[o + 1] << 8)

func u32(b, o):
    return b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)

func u64(b, o):
    return u32(b, o) | (u32(b, o + 4) << 32)

# one chunk's records -> the sink
func unpack_chunk(raw, sink):
    let o = 0
    let n = 0
    while o < len(raw):
        if o + 2 > len(raw):
            fail("a chunk ends inside a record")
        let pl = u16(raw, o)
        let hdr = 2 + pl + 1 + 8 + 8 + 4
        if o + hdr > len(raw):
            fail("a chunk ends inside a record header")
        let path = sslcore.to_str(raw.slice(o + 2, o + 2 + pl))
        if path.find("..", 0) >= 0 or path.starts_with("/"):
            fail("unsafe path in a pack: " .. path)
        let p = o + 2 + pl
        let size = u64(raw, p + 1)
        let offset = u64(raw, p + 9)
        let rlen = u32(raw, p + 17)
        let d = p + 21
        if d + rlen > len(raw) or offset + rlen > size:
            fail("a record runs past its end: " .. path)
        let data = raw.slice(d, d + rlen)
        if path == ".manifest":
            for line in sslcore.to_str(data).split("\n"):
                let f = line.split("\t")
                if f[0] == "L" and len(f) == 3:
                    sink.link(f[1], f[2])
                elif f[0] == "X" and len(f) == 2:
                    sink.executable(f[1])
        else:
            sink.file(path, size, offset, data)
        n += 1
        o = d + rlen
    return n

# download, verify and unpack the pack in folder `dir` of the store ("apps/lua", "firefox"); progress(done_chunks, total) is optional. Returns the pack description.
export func install(src, dir, sink, progress = nil):
    let m = src.get(dir .. "/linuxpack.manifest")
    if m == nil:
        fail("no pack manifest in " .. dir)
    let body = verify(m)
    if body == nil:
        fail("the pack manifest's signature is not valid")
    let pack = parse_pack(body)
    let total = 0
    for i in range(len(pack.chunks)):
        let c = pack.chunks[i]
        let data = src.get(dir .. "/" .. c.file)
        if data == nil:
            fail("chunk " .. c.file .. " could not be downloaded")
        if len(data) != c.size:
            fail("chunk " .. c.file .. " has the wrong size")
        if sslcore.hex(sslcore.hash(256, data)) != c.sha256:
            fail("chunk " .. c.file .. " does not match its SHA-256")
        let raw = sslcore.inflate(data, c.raw)
        if raw == nil or len(raw) != c.raw:
            fail("chunk " .. c.file .. " is not a valid zlib stream of the announced size")
        unpack_chunk(raw, sink)
        total += len(raw)
        if progress != nil:
            progress(i + 1, len(pack.chunks))
    return pack
