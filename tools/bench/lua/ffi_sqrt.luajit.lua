local ffi = require("ffi")
ffi.cdef[[double sqrt(double x);]]
local sqrt = ffi.C.sqrt
local s = 0.0
for i = 0, 19999999 do s = s + sqrt(i) end
print(string.format("%.14g", s))
