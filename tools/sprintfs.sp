# SprintFS image tool.
# usage: sprint run --allow-read=DIR --allow-write=DIR tools/sprintfs.sp IMAGE COMMAND [ARGS]
#   mkfs MEGABYTES [LABEL]       create the image (4096-byte blocks)
#   info                         geometry and free space
#   ls [PATH]                    list a directory (type, mode, size, name)
#   cat PATH                     print a file
#   put LOCAL PATH               copy a local file into the image     get PATH LOCAL   copy a file out
#   mkdir PATH | rm PATH | rmdir PATH | mv OLD NEW | ln-s TARGET PATH
#   stat PATH
#   fsck [--repair]
import fs as host
import sprintfs
import sys
import typed

let a = sys.args
if len(a) < 2:
    print("usage: sprintfs.sp IMAGE COMMAND [ARGS]  (see the comment at the top of tools/sprintfs.sp)")
    sys.exit(2)
let image = a[0]
let cmd = a[1]

func load():
    return sprintfs.device_from_bytes(host.read_bytes(image), 4096)

func save(dev):
    host.write_bytes(image, dev.to_bytes())

func mode_text(st):
    let t = "d" if st.kind == "dir" else ("l" if st.kind == "symlink" else "-")
    let m = st.mode
    let out = t
    for shift in [6, 3, 0]:
        let b = (m >> shift) & 7
        out = out .. ("r" if (b & 4) != 0 else "-") .. ("w" if (b & 2) != 0 else "-") .. ("x" if (b & 1) != 0 else "-")
    return out

if cmd == "mkfs":
    let mb = to_int(a[2])
    let dev = sprintfs.MemDevice(mb * 256, 4096)
    sprintfs.mkfs(dev, {label: a[3] if len(a) > 3 else ""})
    save(dev)
    print("created " .. image .. ": " .. to_string(mb) .. " MiB")
elif cmd == "fsck":
    let dev = load()
    let repair = len(a) > 2 and a[2] == "--repair"
    let r = sprintfs.fsck(dev, repair)
    for e in r.errors:
        print("error: " .. e)
    for f in r.fixed:
        print("fixed: " .. f)
    print(to_string(r.inodes) .. " inodes, " .. to_string(r.blocks_used) .. " blocks in use, " .. to_string(r.files) .. " files, " .. to_string(r.dirs) .. " directories: " .. ("clean" if len(r.errors) == 0 else ("repaired" if repair else "ERRORS")))
    if repair:
        save(dev)
    if len(r.errors) > 0 and not repair:
        sys.exit(1)
else:
    let dev = load()
    let m = sprintfs.mount(dev)
    let changed = false
    if cmd == "info":
        let s = m.statfs()
        print("block size " .. to_string(s.block_size) .. ", " .. to_string(s.blocks) .. " blocks (" .. to_string(s.free_blocks) .. " free), " .. to_string(s.inodes) .. " inodes (" .. to_string(s.free_inodes) .. " free), journal " .. to_string(s.journal_blocks) .. " blocks")
    elif cmd == "ls":
        let p = a[2] if len(a) > 2 else "/"
        for n in m.listdir(p):
            let st = m.lstat((p if p != "/" else "") .. "/" .. n)
            print(mode_text(st) .. " " .. to_string(st.nlink) .. " " .. to_string(st.size) .. " " .. n)
    elif cmd == "cat":
        print(m.read_file(a[2]))
    elif cmd == "stat":
        let st = m.lstat(a[2])
        print("inode " .. to_string(st.ino) .. " " .. st.kind .. " mode " .. mode_text(st) .. " links " .. to_string(st.nlink) .. " size " .. to_string(st.size) .. " blocks " .. to_string(st.blocks) .. " uid " .. to_string(st.uid) .. " gid " .. to_string(st.gid))
    elif cmd == "put":
        m.write_file(a[3], host.read_bytes(a[2]))
        changed = true
    elif cmd == "get":
        host.write_bytes(a[3], m.read_bytes(a[2]))
    elif cmd == "mkdir":
        m.mkdir(a[2])
        changed = true
    elif cmd == "rm":
        m.unlink(a[2])
        changed = true
    elif cmd == "rmdir":
        m.rmdir(a[2])
        changed = true
    elif cmd == "mv":
        m.rename(a[2], a[3])
        changed = true
    elif cmd == "ln-s":
        m.symlink(a[2], a[3])
        changed = true
    else:
        print("unknown command " .. cmd)
        sys.exit(2)
    m.unmount()
    if changed:
        save(dev)
