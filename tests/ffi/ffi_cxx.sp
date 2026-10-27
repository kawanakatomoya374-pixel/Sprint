# C++ (std::vector, std::string, new/delete) behind extern "C" functions
import ffi
ffi.cdef("void *counter_new(void); void counter_add(void *c, int x); int counter_sum(void *c); int counter_max(void *c); void counter_free(void *c);")
ffi.cdef("int reverse_into(const char *s, char *out, int cap);")
let lib = ffi.open("build/libcxxtest.so")
let f = lib.bind(["counter_new", "counter_add", "counter_sum", "counter_max", "counter_free", "reverse_into"])
let c = f.counter_new()
for x in [4, 9, 2, 7]:
    f.counter_add(c, x)
print(f.counter_sum(c), f.counter_max(c))
f.counter_free(c)
let out = ffi.array("i8", 16)
print(f.reverse_into("sprint", out, 16), out.str())
print(f.reverse_into("this is far too long", out, 16))
