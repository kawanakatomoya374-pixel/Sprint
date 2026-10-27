import ffi
ffi.cdef("int add_i32(int a, int b); int64_t mul_i64(int64_t a, int64_t b); double hyp2(double a, double b);")
ffi.cdef("float scale_f(float v, float k); uint8_t u8_inc(uint8_t v); int8_t i8_neg(int8_t v);")
ffi.cdef("uint32_t u32_max(void); uint64_t u64_big(void); int sum6(int,int,int,int,int,int);")
ffi.cdef("double mix(int a, double b, int c, double d);")
ffi.cdef("double sum8d(double a, double b, double c, double d, double e, double f, double g, double h);")
ffi.cdef("const char *greeting(void); size_t slen(const char *s); char *dup_upper(const char *s); void free_str(void *s); const char *null_str(void);")
let lib = ffi.open("build/libctest.so")
let f = lib.bind(["add_i32", "mul_i64", "hyp2", "scale_f", "u8_inc", "i8_neg", "u32_max", "u64_big", "sum6", "mix", "sum8d", "greeting", "slen", "dup_upper", "free_str", "null_str"])
print(f.add_i32(2, 40), f.add_i32(2147483647, 1), f.mul_i64(3000000000, 4))
print(f.hyp2(3, 4.0), f.scale_f(1.5, 2), f.u8_inc(255), f.i8_neg(-128), f.i8_neg(5))
print(f.u32_max(), f.u64_big(), f.sum6(1, 1, 1, 1, 1, 1), f.sum6(1, 2, 3, 4, 5, 6))
print(f.mix(1, 2, 3, 4), f.sum8d(1, 1, 1, 1, 1, 1, 1, 1))
print(f.greeting(), f.slen("héllo"), f.null_str())
# a malloc'd char*: keep the address (void*) to free it, read the text with ffi.string
let raw = lib.fn("dup_upper", "void *dup_upper(const char *s)")
let p = raw("sprint")
print(ffi.string(p), ffi.string(p, 3))
f.free_str(p)
# errors
try:
    f.add_i32(1)
catch e:
    print(e.kind, e.message)
try:
    f.add_i32(1, "x")
catch e:
    print(e.kind)
try:
    f.add_i32(1.5, 2)
catch e:
    print(e.kind)
try:
    lib.fn("nope")
catch e:
    print(e.kind)
try:
    lib.fn("nope", "int nope(void)")
catch e:
    print(e.kind)
try:
    ffi.open("build/does-not-exist.so")
catch e:
    print(e.kind)
let big = lib.fn("sum6", "int sum6(int a, int b, int c, int d, int e, int f, int g)")
try:
    big(1, 2, 3, 4, 5, 6, 7)
catch e:
    print(e.kind)
# libc / libm from the running program, with a varargs function
let c = ffi.open(nil)
let sn = c.fn("snprintf", "int snprintf(char *buf, size_t n, const char *fmt, ...)")
let buf = ffi.array("i8", 64)
print(sn(buf, 64, "%d|%s|%.3f|%c", 7, "ok", 1.5, 65), buf.str())
print(c.fn("pow", "double pow(double, double)")(2, 10), c.fn("labs", "long labs(long)")(-5))
