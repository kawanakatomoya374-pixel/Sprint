import ffi
ffi.cdef("void qsort(void *base, size_t n, size_t size, int (*cmp)(const void *, const void *)); double ldexp(double x, int e);")
let c = ffi.open(nil)
let qs = ffi.fn_at(c.addr("qsort"), "void(void*, size_t, size_t, void*)")
let cbs = []
for k in range(200):
    cbs.append(ffi.callback("int(const void*, const void*)", (p, q) => ffi.view(p, "i32", 1).get(0) - ffi.view(q, "i32", 1).get(0) + k - k))
let ok = true
for k in range(200):
    let a = ffi.array("i32", 5, [5, 3, 9, 1, k])
    qs(a, 5, 4, cbs[k])
    let r = a.to_array()
    for i in range(4):
        if r[i] > r[i + 1]:
            ok = false
print(ok)
