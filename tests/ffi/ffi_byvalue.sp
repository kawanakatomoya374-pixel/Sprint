# structs passed and returned by value (System V x86-64)
import ffi
ffi.cdef("struct V2 { double x, y; }; struct IP { int a; int b; }; struct Mix { int64_t n; double d; };")
ffi.cdef("struct Small { char c; short s; }; struct F3 { float a, b, c; }; struct Big { int64_t a, b, c; }; struct Nest { struct IP p; float x, y; };")
ffi.cdef("double v2_len2(struct V2 v); struct V2 v2_add(struct V2 a, struct V2 b);")
ffi.cdef("int ip_sum(struct IP p); struct IP ip_swap(struct IP p);")
ffi.cdef("double mix_val(struct Mix m, int k); struct Mix mix_make(int64_t n, double d);")
ffi.cdef("struct Small small_make(int c, int s); int small_sum(struct Small s);")
ffi.cdef("float f3_sum(struct F3 f); struct F3 f3_make(float a, float b, float c);")
ffi.cdef("struct Big big_make(int64_t a, int64_t b, int64_t c); int64_t big_sum(const struct Big *b); double nest_val(struct Nest n);")
let lib = ffi.open("build/libctest.so")
let f = lib.bind(["v2_len2", "v2_add", "ip_sum", "ip_swap", "mix_val", "mix_make", "small_make", "small_sum", "f3_sum", "f3_make", "big_make", "big_sum", "nest_val"])

let a = ffi.new("struct V2", {x: 3.0, y: 4.0})
let b = ffi.new("struct V2", {x: 1.5, y: -1.0})
print(f.v2_len2(a))
let c = f.v2_add(a, b)
print(c.get("x"), c.get("y"), c.size())

let p = ffi.new("struct IP", {a: 4, b: 2})
print(f.ip_sum(p))
let q = f.ip_swap(p)
print(q.get("a"), q.get("b"))

let m = f.mix_make(7, 0.25)
print(m.get("n"), m.get("d"), f.mix_val(m, 3))

let s = f.small_make(5, -2)
print(s.get("c"), s.get("s"), f.small_sum(s))

let t = f.f3_make(1.0, 2.0, 4.5)
print(t.get("a"), t.get("b"), t.get("c"), f.f3_sum(t))

let big = f.big_make(10, 20, 30)
print(big.get("a"), big.get("b"), big.get("c"), f.big_sum(big))

let n = ffi.new("struct Nest")
n.get("p").set("a", 1)
n.get("p").set("b", 2)
n.set("x", 3.0)
n.set("y", 4.0)
print(f.nest_val(n))

# structs larger than 16 bytes cannot be passed by value
try:
    ffi.cdef("void takes_big(struct Big b);")
catch e:
    print(e.kind)
# a struct by value needs a struct (an address), not a number
try:
    f.v2_len2(5)
catch e:
    print(e.kind)
