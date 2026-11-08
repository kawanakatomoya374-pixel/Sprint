func counter():
    let n = 0
    func inc():
        n += 1
        return n
    return inc
func pair():
    let n = 0
    func inc():
        n += 1
        return n
    func get():
        return n
    return [inc, get]
func add1(x):
    return x + 1
let f = counter()
let r = 0
for i in range(100000):
    r = f()
print(r)
let g = counter()
let h = 0
for i in range(100000):
    if i == 50000:
        f = g
    h = f()
print(h)
let pr = pair()
let inc = pr[0]
let get = pr[1]
let t = 0
for i in range(100000):
    inc()
    t += get()
print(t)
let a = 0
for i in range(100000):
    a = add1(a)
print(a)
func typed():
    let v = 0
    func bump():
        v += 1
        return v
    return [bump]
let tp = typed()
let b = tp[0]
let z = 0
for i in range(100000):
    z = b()
print(z)
