import math
func fill(n, v):
    let a = []
    a.reserve(n)
    for i in range(n):
        a.append(v)
    return a
func fft(re, im, n, cs, sn):
    let j = 0
    for i in range(n - 1):
        if i < j:
            let tr = re[i]
            let ti = im[i]
            re[i] = re[j]
            im[i] = im[j]
            re[j] = tr
            im[j] = ti
        let m = n >> 1
        while m >= 1 and j >= m:
            j -= m
            m = m >> 1
        j += m
    let size = 2
    while size <= n:
        let half = size >> 1
        let step = n // size
        let k = 0
        while k < n:
            for jj in range(half):
                let wr = cs[jj * step]
                let wi = sn[jj * step]
                let a = k + jj
                let b = a + half
                let xr = re[b] * wr - im[b] * wi
                let xi = re[b] * wi + im[b] * wr
                re[b] = re[a] - xr
                im[b] = im[a] - xi
                re[a] += xr
                im[a] += xi
            k += size
        size = size << 1
let n = 1 << 17
let cs = fill(n, 0.0)
let sn = fill(n, 0.0)
for i in range(n):
    cs[i] = math.cos(-2.0 * math.pi * i / n)
    sn[i] = math.sin(-2.0 * math.pi * i / n)
let acc = 0.0
for r in range(12):
    let re = fill(n, 0.0)
    let im = fill(n, 0.0)
    for i in range(n):
        re[i] = ((i * 31 + r) % 17) / 17.0
    fft(re, im, n, cs, sn)
    acc += re[1] + im[3]
print(math.floor(acc * 1000))
