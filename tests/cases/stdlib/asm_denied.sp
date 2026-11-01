import ffi
try:
    ffi.asm([0xc3], "void()")
catch e:
    print(e.kind)
