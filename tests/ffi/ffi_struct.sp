import ffi
ffi.cdef("""struct Point { int x; int y; };""")
ffi.cdef("struct Rec { char tag; double w; short s[3]; struct Point p; const char *name; };")
ffi.cdef("typedef struct { uint8_t r, g, b, a; } Color;")
ffi.cdef("void pt_move(struct Point *p, int dx, int dy); int pt_dist2(const struct Point *a, const struct Point *b);")
ffi.cdef("struct Point *pt_make(int x, int y); void pt_free(struct Point *p);")
ffi.cdef("int rec_size(void); int rec_off_p(void); void rec_fill(struct Rec *r); uint32_t color_pack(const Color *c);")
ffi.cdef("double dot(const double *a, const double *b, int n); void fill_squares(int *out, int n); void set_out(int *a, double *b);")
let lib = ffi.open("build/libctest.so")
let f = lib.bind(["pt_move", "pt_dist2", "pt_make", "pt_free", "rec_size", "rec_off_p", "rec_fill", "color_pack", "dot", "fill_squares", "set_out"])

# layout agrees with the C compiler
print(ffi.sizeof("struct Rec"), f.rec_size(), ffi.offsetof("struct Rec", "p"), f.rec_off_p())
print(ffi.sizeof("struct Point"), ffi.sizeof("Color"), ffi.sizeof("Point"))

# structs by pointer
let a = ffi.new("struct Point", {x: 3, y: 4})
let b = ffi.new("Point")
f.pt_move(a, 10, -1)
print(a.get("x"), a.get("y"), f.pt_dist2(a, b), a.to_table())
b.set("x", 1)
print(f.pt_dist2(a, b))

# returned pointer becomes a struct view
let m = f.pt_make(5, 6)
print(m.get("x"), m.get("y"), m.size())
m.set("y", 60)
print(f.pt_dist2(m, b))
f.pt_free(m)

# nested struct, array and string fields
let r = ffi.new("struct Rec")
f.rec_fill(r)
print(r.get("tag"), r.get("w"), r.get("s").to_array(), r.get("s", 1), r.get("p").get("x"), r.get("p").get("y"), r.get("name"))
r.get("p").set("x", 70)
r.set("s", 99, 2)
print(r.get("p").get("x"), r.get("s").to_array())
r.set("name", "changed")
print(r.get("name"))
try:
    r.get("nope")
catch e:
    print(e.kind)
try:
    r.get("s", 3)
catch e:
    print(e.kind)

# typedef'd anonymous struct
let col = ffi.new("Color", {r: 1, g: 2, b: 3, a: 4})
print(f.color_pack(col))

# arrays and out parameters
let xs = ffi.array("f64", 3, [1.0, 2.0, 3.0])
let ys = ffi.array("f64", 3, [4.0, 5.0, 6.0])
print(f.dot(xs, ys, 3))
let sq = ffi.array("i32", 6)
f.fill_squares(sq, 6)
print(sq.to_array(), sq.get(5), sq.count())
try:
    sq.get(6)
catch e:
    print(e.kind)
let oa = ffi.new("int")
let ob = ffi.new("double")
f.set_out(oa, ob)
print(oa.get(), ob.get())
let cs = ffi.cstr("abc")
print(cs.count(), cs.str(), ffi.string(cs), ffi.string(cs, 2))
let big = ffi.new("int[4]", [9, 8])
print(big.to_array())
