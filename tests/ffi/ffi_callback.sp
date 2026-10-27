import ffi
ffi.cdef("int apply_i(int (*cb)(int), int v); double apply_d(double (*cb)(double, double), double a, double b); float apply_f(float (*cb)(float), float v);")
ffi.cdef("int each_str(const char *const *items, int n, int (*cb)(const char *, int)); void sort_ints(int *a, int n, int (*cmp)(const void *, const void *));")
ffi.cdef("typedef int (*binop)(int, int); int add_i32(int a, int b);")
let lib = ffi.open("build/libctest.so")
let f = lib.bind(["apply_i", "apply_d", "apply_f", "each_str", "sort_ints"])

# a plain Sprint function as an argument: wrapped for the duration of the call
print(f.apply_i(x => x * 10, 4))
print(f.apply_d((a, b) => a - b, 10.0, 2.5), f.apply_f(v => v + 0.25, 1.0))
let calls = []
print(f.apply_i(x => calls.append(x) or 0, 7), calls)

# explicit callbacks; qsort-style comparator reading C memory
let cmp = ffi.callback("int(const void*, const void*)", (p, q) => ffi.view(p, "i32", 1).get(0) - ffi.view(q, "i32", 1).get(0))
let arr = ffi.array("i32", 6, [5, 2, 9, 1, 5, 6])
f.sort_ints(arr, 6, cmp)
print(arr.to_array())
let desc = ffi.callback("int(const void*, const void*)", (p, q) => ffi.view(q, "i32", 1).get(0) - ffi.view(p, "i32", 1).get(0))
f.sort_ints(arr, 6, desc)
print(arr.to_array())
cmp.release()
desc.release()
print(cmp.addr())

# C strings arrive as Sprint strings
let items = ffi.array("p", 3)
let keep = [ffi.cstr("a"), ffi.cstr("bcd"), ffi.cstr("ef")]
for i in range(3):
    items.set(i, keep[i])
let seen = []
print(f.each_str(items, 3, (s, i) => seen.append(s .. to_string(i)) or len(s)), seen)

# an error inside a callback surfaces from the call that triggered it
try:
    f.apply_i(x => x / 0, 1)
catch e:
    print(e.kind)
try:
    f.apply_i(x => "no", 1)
catch e:
    print(e.kind)
# the pool is finite and slots are reusable
let cbs = [ffi.callback("int(int)", x => x) for i in range(16)]
try:
    ffi.callback("int(int)", x => x)
catch e:
    print(e.kind)
for c in cbs:
    c.release()
let again = ffi.callback("int(int)", x => x + 1)
print(ffi.fn_at(again, "int(int)")(41))
again.release()
# function pointers called from Sprint, typedef'd function pointer types
let add = lib.addr("add_i32")
print(ffi.fn_at(add, "int(int, int)")(20, 22))
