local function counter() local n = 0 return function() n = n + 1 return n end end
local function run(f, k) local r = 0 for i = 1, k do r = f() end return r end
print(run(counter(), 200000000))
