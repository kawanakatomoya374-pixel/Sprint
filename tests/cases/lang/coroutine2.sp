import coroutine
import gc

func gen(n):
    let items = []
    defer print("gen done", n)
    for i in range(n):
        items.append("item" .. i)
        gc.collect()
        yield items[i]

let total = 0
for k in range(200):
    let co = coroutine.create(func(): gen(3), 128)
    for s in co:
        total += len(s)
print(total)

let live = []
for k in range(50):
    let co = coroutine.create(func(): gen(2), 128)
    coroutine.resume(co)
    live.append(co)
gc.collect()
for co in live:
    coroutine.close(co)
print(coroutine.status(live[0]), len(live))

func deep(n):
    if n == 0:
        yield "bottom"
        return 0
    return deep(n - 1)
let d = coroutine.create(func(): deep(20), 512)
print(coroutine.resume(d))
func recurse(n):
    return recurse(n + 1) + 1
let r = coroutine.create(func(): recurse(0), 64)
coroutine.resume(r)
