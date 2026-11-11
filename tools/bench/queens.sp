func fill(n, v):
    let a = []
    a.reserve(n)
    for i in range(n):
        a.append(v)
    return a
func solve(n, row, cols, d1, d2):
    if row == n:
        return 1
    let c = 0
    for col in range(n):
        if cols[col] == 0 and d1[row + col] == 0 and d2[row - col + n] == 0:
            cols[col] = 1
            d1[row + col] = 1
            d2[row - col + n] = 1
            c += solve(n, row + 1, cols, d1, d2)
            cols[col] = 0
            d1[row + col] = 0
            d2[row - col + n] = 0
    return c
let n = 12
print(solve(n, 0, fill(n, 0), fill(2 * n, 0), fill(2 * n + 1, 0)))
