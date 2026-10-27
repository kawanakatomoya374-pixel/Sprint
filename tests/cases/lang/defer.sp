func log(s):
    print("log", s)

func a():
    defer log("a-end")
    for i in range(3):
        defer log("iter " .. i)
        if i == 1:
            continue
        print("body", i)
    defer print("late")
    return "ret-a"

print(a())

func b():
    defer log("b1")
    defer log("b2")
    throw error("Boom", "from b")

try:
    b()
catch e:
    print("caught", e.kind)

func c():
    let xs = []
    defer xs.append(1)
    try:
        defer log("inner")
        throw error("E1", "first")
    catch e:
        print("c caught", e.message)
    return len(xs)
print(c())

func bad():
    throw error("E2", "second")

func d():
    defer bad()
    throw error("E1", "first")
try:
    d()
catch e:
    print(e.kind, e.suppressed.kind)

func f():
    defer bad()
    return 5
try:
    f()
catch e:
    print("f threw", e.kind)

let n = 0
while true:
    defer log("loop defer")
    n += 1
    if n == 2:
        break
print("after loop", n)
func p():
    defer log("p-defer")
    panic "stop!"
p()
