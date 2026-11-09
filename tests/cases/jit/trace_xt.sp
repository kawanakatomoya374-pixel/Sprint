func sum(a, n):
    let s = 0
    for rep in range(50):
        for i in range(n):
            s += a[i]
    return s
let a = []
for i in range(10):
    a.append(i)
print(sum(a, 10))
a[3] = 100
print(sum(a, 10))
a.insert(0, 5)
print(sum(a, 10))
let b = [1, 2]
b.extend(a)
print(sum(b, 10))
let c = []
for i in range(10):
    c.append(i + 1)
print(sum(c, 10))
c[4] = 1.5
try:
    print(sum(c, 10))
catch err:
    print(err.kind)
let d = []
for i in range(10):
    d.append(i)
d[2] = "x"
try:
    print(sum(d, 10))
catch err:
    print(err.kind)
d[2] = 7
print(sum(d, 10))
func rows(m, n):
    let t = 0
    for rep in range(50):
        for r in range(n):
            let row = m[r]
            for k in range(n):
                t += row[k]
    return t
let m = []
for i in range(5):
    let row = []
    for j in range(5):
        row.append(i * j)
    m.append(row)
print(rows(m, 5))
m[2][3] = "s"
try:
    print(rows(m, 5))
catch err:
    print(err.kind)
m[2][3] = 2
m[1] = [9, 9, 9, 9, 9]
print(rows(m, 5))
func writer(a, n):
    for rep in range(50):
        for i in range(n):
            a[i] = a[i] + 1
    return a[0]
let w = []
for i in range(10):
    w.append(i)
print(writer(w, 10), sum(w, 10))
let e = []
e.append(1)
e.pop()
e.append("s")
print(e[0])
