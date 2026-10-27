import vfs
import proc

# vfs
print(vfs.normalize("../../a/./b/../c", "/x/y"), vfs.basename("/a/b/c.txt"), vfs.dirname("/a/b/c.txt"), vfs.dirname("/a"), vfs.join("/a", "../b"))
let f = vfs.FS()
f.mkdir("/usr/bin", true)
f.write("/usr/bin/hello", "echo hi")
f.append("/usr/bin/hello", "!")
f.chdir("/usr")
print(f.ls("."), f.read("bin/hello"), f.stat("bin/hello").size, f.is_dir("bin"), f.is_file("bin"), f.exists("nope"))
f.cp("bin", "/copy")
f.mv("/copy", "/usr/b2")
print(f.walk("/"))
for bad in [() => f.rm("/usr"), () => f.read("/usr"), () => f.mkdir("/usr"), () => f.write("/nodir/x", "1"), () => f.chdir("/usr/bin/hello"), () => f.cp("/usr", "/usr/in")]:
    try:
        bad()
    catch e:
        print(e)
f.rm("/usr", true)
print(f.walk("/"))
let g = vfs.FS()
g.mkdir("/a/b", true)
g.write("/a/b/f", "x")
let h = vfs.FS()
h.load(g.dump())
print(h.read("/a/b/f"), h.cwd)

# processes
let k = proc.Kernel()
func worker(sys, args):
    for i in range(3):
        sys.print(args[0] .. to_string(i))
        sys.sleep(5)
    return 7
func server(sys, args):
    while true:
        let m = sys.recv()
        if m == "quit":
            sys.exit(3)
        sys.print("got " .. m)
func parent(sys, args):
    let c = sys.spawn("child", (s, a) => s.print("child of " .. to_string(sys.pid)))
    sys.yield_now()
    sys.print("parent done")
let a = k.spawn("w", worker, ["a"])
let b = k.spawn("srv", server)
k.step(2)
k.send(b, "hi")
k.step(3)
print(k.ps(), k.stdout)
print(k.send(99, "x"), k.send(b, "quit"))
k.spawn("par", parent)
k.run_all()
print(k.exit_code(a), k.exit_code(b), k.now, k.stdout)
print(k.ps(), k.alive(a))
let spin = k.spawn("spin", (sys, args) => sys.sleep(1000000))
k.step(3)
print(k.kill(spin), k.kill(spin), k.exit_code(spin), len(k.ps()))

# shell
let sh = proc.Shell(k)
sh.install("hello", (sys, args) => sys.print("hello " .. args.join("+")))
let cmds = ["mkdir /a/b", "write /a/b/f x y", "cat /a/b/f", "hello 1 2", "ls /a", "cd /a", "pwd", "cp b/f g", "ls", "tree /", "rm b", "rm -r b", "ls", "cat /nope", "zz", "help"]
for c in cmds:
    print(sh.prompt() .. c, "=>", sh.run(c).replace("\n", "|"))
