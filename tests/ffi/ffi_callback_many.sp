# more than 16 callbacks alive at once (integer and floating-point returns), then released and reused
import ffi
ffi.cdef("int apply_i(int (*cb)(int), int v); double apply_d(double (*cb)(double, double), double a, double b);")
let lib = ffi.open("build/libctest.so")
let f = lib.bind(["apply_i", "apply_d"])
let ints = []
let dbls = []
for k in range(300):
    ints.append(ffi.callback("int(int)", x => x + k))
    dbls.append(ffi.callback("double(double, double)", (a, b) => a * b + k))
let ai = ffi.fn_at(lib.addr("apply_i"), "int(void*, int)")
let ad = ffi.fn_at(lib.addr("apply_d"), "double(void*, double, double)")
let ok = true
for k in range(300):
    if ai(ints[k], 1000) != 1001 + k or ad(dbls[k], 3.0, 2.0) != 12.0 + 2 * k:
        ok = false
print(ok, ints[299].addr() != ints[0].addr())
for c in ints:
    c.release()
let again = ffi.callback("int(int)", x => x * 2)
print(ai(again, 21))
again.release()
for c in dbls:
    c.release()
