import ffi
ffi.cdef("double sqrt(double x);")
let sqrt = ffi.open(nil).fn("sqrt")
let s = 0.0
for i in range(20000000):
    s += sqrt(to_float(i))
print(s)
