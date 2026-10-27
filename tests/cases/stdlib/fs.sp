import fs
let d = "build/fstest"
if fs.exists(d):
    for n in fs.list_dir(d):
        fs.remove(d .. "/" .. n)
    fs.remove(d)
fs.make_dir(d)
print(fs.is_dir(d), fs.is_file(d), fs.exists(d .. "/a.txt"))
fs.write_file(d .. "/a.txt", "héllo\n")
fs.append_file(d .. "/a.txt", "world\n")
fs.write_file(d .. "/b.txt", "x")
fs.write_file(d .. "/B.txt", "y")
print(fs.read_file(d .. "/a.txt").split_lines())
print(fs.list_dir(d))
try:
    fs.read_file(d .. "/nope")
catch e:
    print(e.kind, e.data.op, e.data.errno > 0)
try:
    fs.make_dir(d)
catch e:
    print(e.kind)
try:
    fs.make_dir(d .. "/x/y")
catch e:
    print(e.kind)
try:
    fs.read_file("/etc/passwd")
catch e:
    print(e.kind)
try:
    fs.read_file(d .. "/../../SPEC.md")
catch e:
    print(e.kind)
for n in fs.list_dir(d):
    fs.remove(d .. "/" .. n)
fs.remove(d)
print(fs.exists(d))
