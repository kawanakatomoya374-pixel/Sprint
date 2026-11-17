import ffi
ffi.cdef("double sqrt(double x);")
let csqrt = ffi.open(nil).fn("sqrt")
let s = 0.0
for i in range(3000):
    s += csqrt(to_float(i))
print(s)
let t = 0.0
for i in range(3000):
    t += to_float(i % 7) * 0.5 + to_float(i * 0.25)
print(t)
let neg = 0
for i in range(-20, 3000):
    let v = csqrt(to_float(i))
    if v != v:
        neg += 1
print(neg)
