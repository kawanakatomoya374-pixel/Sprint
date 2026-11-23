#!/usr/bin/env python3
"""The file system as a user-space server. Boot a SprintOS image (the Sprint BIOS bootloader, kernel command line init=fstest) with a second ATA disk
formatted with SprintFS on the host (tools/sprintfs.sp). The kernel knows nothing about disks or files: the program fsd (ring 3, Sprint) is given the
disk's I/O ports, mounts the volume, and fstest talks to it with messages. Afterwards the host reads what was written and runs fsck."""
import os, subprocess, sys, tempfile
IMG = sys.argv[1]
SP = os.environ.get("SPRINT", "build/sprint")
tmp = tempfile.mkdtemp()
fsimg, ser = os.path.join(tmp, "fs.img"), os.path.join(tmp, "serial.log")
open(os.path.join(tmp, "hello.txt"), "w").write("hello from SprintFS inside SprintOS\n")
def tool(*a):
    return subprocess.run([SP, "run", "--allow-read=" + tmp, "--allow-write=" + tmp, "tools/sprintfs.sp", fsimg] + list(a), capture_output=True, text=True)
tool("mkfs", "8"); tool("put", os.path.join(tmp, "hello.txt"), "/hello.txt")
try:
    subprocess.run(["qemu-system-x86_64", "-m", "256", "-smp", "2", "-drive", "format=raw,file=" + IMG + ",if=ide,index=0",
                    "-drive", "format=raw,file=" + fsimg + ",if=ide,index=1", "-display", "none", "-no-reboot", "-serial", "file:" + ser,
                    "-device", "isa-debug-exit,iobase=0xf4,iosize=4"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=120)
except subprocess.TimeoutExpired:
    pass
log = open(ser, errors="replace").read()
fails = []
def check(c, what):
    print(("ok   " if c else "FAIL ") + what)
    if not c: fails.append(what)
check("[fsd] mounted SprintFS from" in log, "fsd (a user process) found the disk through its I/O ports and mounted the volume")
check("not SprintFS" in log, "the boot disk is probed too and skipped")
check("fstest: /hello.txt: hello from SprintFS inside SprintOS" in log, "a file written on the host reads back through the server")
check("fstest: read back: written through the file system server" in log, "write + read through the server")
import re
check(re.search(r"big file \d{6,} bytes, round trip ok", log) is not None, "a file larger than the shared buffer round-trips byte for byte")
check("partial write: 89XYZ010" in log, "a write at an offset")
check("fstest: after rename/unlink: b.txt" in log, "rename and unlink")
check("missing file: ENOENT" in log and "mkdir again: EEXIST" in log, "errors come back with SprintFS's error kinds")
check("fstest: fsd exited with 0" in log and "fstest: done" in log, "the server syncs and exits on request")
check("physical pages" in log and "[kernel] disk" not in log, "the kernel itself mounts and drives no disk")
check("written through the file system server" in tool("cat", "/docs/b.txt").stdout, "the host reads the file the server wrote")
check("clean" in tool("fsck").stdout, "fsck on the host: the volume is clean")
sys.exit(1 if fails else 0)
