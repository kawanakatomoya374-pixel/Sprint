func fill(n, v):
    let a = []
    a.reserve(n)
    for i in range(n):
        a.append(v)
    return a
func fannkuch(n):
    let perm1 = []
    for i in range(n):
        perm1.append(i)
    let perm = fill(n, 0)
    let count = fill(n, 0)
    let max_flips = 0
    let checksum = 0
    let nperm = 0
    let r = n
    while true:
        while r != 1:
            count[r - 1] = r
            r -= 1
        for i in range(n):
            perm[i] = perm1[i]
        let flips = 0
        let k = perm[0]
        while k != 0:
            let i = 0
            let j = k
            while i < j:
                let t = perm[i]
                perm[i] = perm[j]
                perm[j] = t
                i += 1
                j -= 1
            flips += 1
            k = perm[0]
        if flips > max_flips:
            max_flips = flips
        if nperm % 2 == 0:
            checksum += flips
        else:
            checksum -= flips
        while true:
            if r == n:
                print(checksum)
                return max_flips
            let p0 = perm1[0]
            for i in range(r):
                perm1[i] = perm1[i + 1]
            perm1[r] = p0
            count[r] -= 1
            if count[r] > 0:
                break
            r += 1
        nperm += 1
print(fannkuch(10))
