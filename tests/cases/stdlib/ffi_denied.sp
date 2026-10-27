import ffi
try:
    ffi.open(nil)
catch e:
    print(e.kind)
try:
    ffi.array("i32", 2)
catch e:
    print(e.kind)
print(ffi.sizeof("int"), ffi.sizeof("double[3]"))
ffi.cdef("struct P { char c; double d; int i; }; typedef unsigned long ul;")
print(ffi.sizeof("struct P"), ffi.offsetof("struct P", "d"), ffi.offsetof("struct P", "i"), ffi.sizeof("ul"))
try:
    ffi.cdef("struct Bad { int x ")
catch e:
    print(e.kind)
try:
    ffi.cdef("union U { int a; float b; };")
catch e:
    print(e.kind)
