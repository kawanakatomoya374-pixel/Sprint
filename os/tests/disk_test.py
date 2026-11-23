#!/usr/bin/env python3
"""Boot a SprintOS image with a second, SprintFS-formatted ATA disk (made on the host by tools/sprintfs.sp), and check that the Sprint kernel finds it
with its ATA driver, mounts it, reads /hello.txt, writes /booted.txt and syncs it, and that the host then finds the written file and a clean fsck."""
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
                    "-device", "isa-debug-exit,iobase=0xf4,iosize=4"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=90)
except subprocess.TimeoutExpired:
    pass
log = open(ser, errors="replace").read()
fails = []
def check(c, what):
    print(("ok   " if c else "FAIL ") + what)
    if not c: fails.append(what)
check("sprintfs mounted from" in log, "the kernel finds the SprintFS disk (ATA PIO driver in Sprint) and mounts it")
check("disk QEMU HARDDISK is not a SprintFS volume" in log, "the boot disk is probed too and skipped (not SprintFS)")
check("/hello.txt: hello from SprintFS inside SprintOS" in log, "a file written on the host reads back inside SprintOS")
check("wrote /booted.txt and synced" in log, "the kernel writes a file and syncs")
check("written by the Sprint kernel" in tool("cat", "/booted.txt").stdout, "the host reads the file the kernel wrote")
check("clean" in tool("fsck").stdout, "fsck on the host: the volume is clean after the in-kernel writes")
sys.exit(1 if fails else 0)
