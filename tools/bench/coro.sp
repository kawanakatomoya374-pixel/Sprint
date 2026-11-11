import coroutine
func gen(n):
    let i = 0
    while i < n:
        yield i
        i += 1
func filter_odd(src):
    while coroutine.status(src) != "dead":
        let v = coroutine.resume(src)
        if coroutine.status(src) == "dead":
            return
        if v % 2 == 1:
            yield v
let p = coroutine.create(func(): gen(1500000))
let f = coroutine.create(func(): filter_odd(p))
let sum = 0
while true:
    let v = coroutine.resume(f)
    if coroutine.status(f) == "dead":
        break
    sum += v
print(sum)
