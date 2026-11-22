# unions and bit-fields in ffi.cdef: layout equal to the C compiler's (SysV), values round-trip
import ffi
ffi.cdef("""
union V { int32_t i; float f; uint8_t b[4]; };
struct Flags { unsigned a : 3; unsigned b : 5; int c : 4; uint8_t tail; };
struct W { int x; union V v; };
struct Mix { uint8_t p : 4; uint8_t q : 4; uint8_t r : 4; uint16_t s; };
""")
let v = ffi.new("union V")
v.set("i", 0x3f800000)
print(v.get("f"), v.get("b", 3), v.size())
let f = ffi.new("struct Flags")
f.set("a", 5)
f.set("b", 17)
f.set("c", -3)
f.set("tail", 9)
print(f.get("a"), f.get("b"), f.get("c"), f.get("tail"), f.size())
print(ffi.view(f.addr(), "u8", 4).to_array())
f.set("a", 2)
print(f.get("a"), f.get("b"), f.get("c"))
let w = ffi.new("struct W")
w.get("v").set("f", 2.5)
print(w.get("v").get("i"), w.size(), ffi.sizeof("union V"), ffi.offsetof("struct W", "v"))
let m = ffi.new("struct Mix")
m.set("p", 15)
m.set("q", 1)
m.set("r", 9)
m.set("s", 513)
print(m.size(), ffi.view(m.addr(), "u8", 4).to_array(), m.get("p"), m.get("q"), m.get("r"), m.get("s"))
