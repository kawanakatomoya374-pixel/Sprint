import math
# float arguments take the VM's shortcut; everything else must behave exactly as before
print(math.sqrt(16.0), math.sqrt(2.0), math.sqrt(0.0))
print(math.sqrt(16), math.sqrt(2))
print(math.sin(0.0), math.cos(0.0), math.exp(0.0), math.tan(0.0), math.atan(0.0))
print(math.sin(1), math.exp(1), math.is_nan(math.sqrt(math.nan)))
print(math.sqrt(math.inf))
try:
    math.sqrt(-1.0)
catch e:
    print(e.kind, e.message)
try:
    math.sqrt("x")
catch e:
    print(e.kind)
let m = math.sqrt
print(m(9.0))
let s = 0.0
for i in range(1000):
    s += math.sqrt(i + 0.0) + math.cos(i * 0.01)
print(s)
