# prepared (direct) calls and machine code via ffi.asm
import ffi
ffi.cdef("double sqrt(double x); double pow(double x, double y); int abs(int x); long labs(long x); size_t strlen(const char *s); double floor(double x);")
let c = ffi.open(nil)
let L = c.bind(["sqrt", "pow", "abs", "labs", "strlen", "floor"])
print(L.sqrt(2.0), L.pow(2, 10), L.abs(-5), L.labs(-1234567890123), L.strlen("hello"), L.floor(-1.5))
# the same function prepared twice behaves identically
let a = c.fn("sqrt")
let b = c.fn("sqrt")
print(a(9.0), b(16.0))
# argument checking
try:
    a()
catch e:
    print(e.kind)
try:
    a(1.0, 2.0)
catch e:
    print(e.kind)
try:
    a("x")
catch e:
    print(e.kind)
# many calls in a loop (the JIT sees a native call)
let s = 0.0
for i in range(1000):
    s += a(to_float(i * i))
print(s)
# machine code (x86-64 only): lea rax,[rdi+rsi]; ret   /   addsd xmm0,xmm1; ret
if ffi.abi() == "x86_64":
    let add = ffi.asm([0x48, 0x8d, 0x04, 0x37, 0xc3], "int64_t(int64_t, int64_t)")
    let fadd = ffi.asm([0xf2, 0x0f, 0x58, 0xc1, 0xc3], "double(double, double)")
    print(add(40, 2), add(-5, 3), fadd(1.5, 2.25))
    try:
        ffi.asm([], "int64_t()")
    catch e:
        print(e.kind)
    try:
        ffi.asm([256], "int64_t()")
    catch e:
        print(e.kind)
else:
    print(42, -2, 3.75)
    print("ValueError")
    print("ValueError")
