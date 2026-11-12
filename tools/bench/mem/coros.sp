import coroutine
func body(k):
    let i = 0
    while true:
        yield i + k
        i += 1
let cs = []
for k in range(20000):
    let c = coroutine.create(func(): body(k), 128)
    coroutine.resume(c)
    cs.append(c)
let s = 0
for r in range(10):
    for c in cs:
        s += coroutine.resume(c)
print(s, len(cs))
