let r = range(5)
print(type(r))
for i in r:
    print(i)
for i in r:
    print("again", i)
let t = 0
for c in "aé😀".codepoints():
    print(c)
for x in range(10, 0, -3):
    t += x
print(t)
let r2 = range(2)
try:
    for a, b in r2:
        print(a)
catch e:
    print(e.kind)
try:
    range(1, 2.5)
catch e:
    print(e.kind)
for i in range(9223372036854775800, 9223372036854775807, 4):
    print(i)
