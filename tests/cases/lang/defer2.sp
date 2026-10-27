import gc
func cleanup(tag, items):
    gc.collect()
    print("cleanup", tag, len(items))

func work(n):
    let items = []
    defer cleanup("w" .. n, items)
    for i in range(n):
        items.append("x" .. i)
    if n > 2:
        work(n - 1)
    if n == 2:
        throw error("Deep", "n=2")
    return n

try:
    work(4)
catch e:
    print("caught", e.kind, e.message)

func nested():
    defer print("outer-1")
    func inner():
        defer print("inner-1")
        defer print("inner-2")
        return 7
    let v = inner()
    defer print("outer-2")
    return v
print(nested())
