let t = {}
for i in range(20000):
    t["k" .. i] = [i, "v" .. i]
let sum = 0
for i in range(20000):
    sum += t["k" .. i][0]
print(sum, len(t))
for i in range(0, 20000, 2):
    delete(t, "k" .. i)
print(len(t))
let a = []
for i in range(100000):
    a.append(i .. "")
print(len(a), a[99999])
func deep(n):
    if n == 0:
        return 0
    return 1 + deep(n - 1)
print(deep(500))
deep(100000)
