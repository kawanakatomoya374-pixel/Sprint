func solve(n, cols, d1, d2, all):
    if cols == all:
        return 1
    let cnt = 0
    let avail = all & ~(cols | d1 | d2)
    while avail != 0:
        let bit = avail & -avail
        avail ^= bit
        cnt += solve(n, cols | bit, ((d1 | bit) << 1) & all, (d2 | bit) >> 1, all)
    return cnt
let total = 0
for n in range(6, 13):
    total += solve(n, 0, 0, 0, (1 << n) - 1)
print(total)
