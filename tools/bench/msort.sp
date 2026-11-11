func merge_sort(a, tmp, lo, hi):
    if hi - lo < 2:
        return
    let mid = (lo + hi) // 2
    merge_sort(a, tmp, lo, mid)
    merge_sort(a, tmp, mid, hi)
    let i = lo
    let j = mid
    let k = lo
    while i < mid and j < hi:
        if a[i] <= a[j]:
            tmp[k] = a[i]
            i += 1
        else:
            tmp[k] = a[j]
            j += 1
        k += 1
    while i < mid:
        tmp[k] = a[i]
        i += 1
        k += 1
    while j < hi:
        tmp[k] = a[j]
        j += 1
        k += 1
    for x in range(lo, hi):
        a[x] = tmp[x]
let n = 1500000
let a = []
let tmp = []
let seed = 3
for i in range(n):
    seed = (seed * 16807) % 2147483647
    a.append(seed)
    tmp.append(0)
merge_sort(a, tmp, 0, n)
let ok = true
for i in range(1, n):
    if a[i - 1] > a[i]:
        ok = false
print(ok, a[0], a[n - 1])
