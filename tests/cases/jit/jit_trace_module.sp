# loops over module-level variables, compiled by the TraceJIT: the variables live in scratch slots while the trace runs and are written
# back on every exit (normal end, deopt, error)
let s = 0
for i in range(5000):
    s += i % 7
print(s)

let a = 1
let b = 2
let k = 0
while k < 3000:
    if k % 2 == 0:
        a = a + k
    else:
        b = b + k * 3
    k += 1
print(a, b, k)

# a module variable that changes type: the trace leaves, the interpreter carries on
let t = 0
let j = 0
while j < 3000:
    if j == 2900:
        t = t + 0.5
    t = t + j
    j += 1
print(t, j)

# an error in the middle: the variables must hold what the interpreter would have left
let d = 10
let acc = 0
let n = 0
try:
    while n < 5000:
        acc = acc + 1000 // d
        d -= 1
        n += 1
catch e:
    print(e.kind)
print(acc, d, n)

# arrays held in module variables
let arr = []
for x in range(2000):
    arr.append(x)
let tot = 0
for x in range(2000):
    arr[x] = arr[x] * 2 + 1
    tot += arr[x]
print(tot, arr[0], arr[1999])

# an overflow in the middle of the loop
let big = 1
let m = 0
try:
    for x in range(100):
        big = big * 3
        m += 1
catch e:
    print(e.kind)
print(big, m)

# the same variables used by a function afterwards
func peek():
    return [s, a, b, k, tot, m]
print(peek())
