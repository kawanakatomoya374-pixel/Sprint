import coroutine

func count_up(limit):
    let i = 1
    while i <= limit:
        yield i
        i += 1

func counter(limit):
    return coroutine.create(func(): count_up(limit))

let result = []
for x in counter(3):
    result.append(x)
print(result, deep_equal(result, [1, 2, 3]))

let co = coroutine.create(func(): count_up(2))
print(coroutine.status(co))
print(coroutine.resume(co), coroutine.status(co))
print(coroutine.resume(co))
print(coroutine.resume(co), coroutine.status(co))
try:
    coroutine.resume(co)
catch e:
    print(e.kind)

func boom():
    yield 1
    throw error("Oops", "inside")
let b = coroutine.create(boom)
print(coroutine.resume(b))
try:
    coroutine.resume(b)
catch e:
    print("caught", e.kind, e.message, coroutine.status(b))

func with_defer():
    defer print("cleanup ran")
    yield 1
    yield 2
let w = coroutine.create(with_defer)
coroutine.resume(w)
coroutine.close(w)
print(coroutine.status(w))

func gen_inner():
    yield "a"
    yield "b"
func gen_outer():
    let inner = coroutine.create(gen_inner)
    for v in inner:
        yield v .. "!"
    yield "done"
for v in coroutine.create(gen_outer):
    print(v)
print(coroutine.current())

func whoami():
    print(coroutine.status(coroutine.current()))
    yield 0
let c2 = coroutine.create(whoami)
coroutine.resume(c2)
