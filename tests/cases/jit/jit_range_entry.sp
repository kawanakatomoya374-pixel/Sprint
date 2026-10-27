# a hot range loop is compiled while it runs (its range_prep is outside the compiled region): the step is checked on entry
func sum(a, b, step):
    let s = 0
    for i in range(a, b, step):
        s += i
    return s

print(sum(0, 3000, 1))
print(sum(0, 3000, 1))
print(sum(0, 3000, 3))
print(sum(3000, 0, -1))
print(sum(3000, 0, -7))
print(sum(0, 3000, 2))
print(sum(5, 3000, 1))

let t = 0
for k in range(30):
    t += sum(0, 500, 1 + k % 3)
    t += sum(500, 0, -1 - k % 2)
print(t)

let u = 0
let st = 1
for n in range(5):
    for i in range(0, 2000, st):
        u += i % 7
    st = st + 1
print(u)
