let s = 0
for i in range(30000000):
    s += i
print(s)
let t = 0
for k in range(3):
    for i in range(10, 0, -3):
        t += i
    for i in range(0, 20, 7):
        t += i * 2
for i in range(9223372036854775800, 9223372036854775807, 4):
    t += 1
print(t)
