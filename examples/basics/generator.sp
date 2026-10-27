import coroutine

func fib_gen(limit):
    let a = 0
    let b = 1
    while a < limit:
        yield a
        let t = a + b
        a = b
        b = t

let co = coroutine.create(func(): fib_gen(100))
for v in co:
    print(v)
