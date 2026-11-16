# values kept on the stack across a branch join (`a[k] = (a[k] ?? 0) + 1`, conditional expressions) keep what they were seen to
# hold: a dict receiver stays a dict. Mixed receivers (dict, array) and keys that are present and absent must give the
# interpreter's results.
let counts = {}
let arr = []
for i in range(16):
    arr.append(0)
let seed = 31
let miss = 0
for i in range(40000):
    seed = (seed * 16807) % 2147483647
    let k = seed % 64
    counts[k] = (counts[k] ?? 0) + 1
    arr[k % 16] = (arr[k % 16] ?? 0) + 2
    let d = counts[k % 7] ?? -1
    if d < 0:
        miss += 1
let mx = 0
let arg = 0
for k, v in counts:
    if v > mx:
        mx = v
        arg = k
let t = 0
for v in arr:
    t += v
print(len(counts), mx, arg, t, miss)
# the same join with a receiver that changes kind between loops
func bump(c, k):
    c[k] = (c[k] ?? 0) + 1
let da = {}
let aa = [0, 0, 0, 0]
for i in range(3000):
    bump(da, i % 5)
    bump(aa, i % 4)
print(len(da), da[0], da[4], aa[0], aa[3])
let s = 0
for i in range(5000):
    let v = (da[i % 6] ?? 7) if i % 3 == 0 else (aa[i % 4] ?? 9)
    s += v
print(s)
