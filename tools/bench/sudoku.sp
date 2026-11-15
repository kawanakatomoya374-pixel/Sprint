func fill(n, v):
    let a = []
    a.reserve(n)
    for i in range(n):
        a.append(v)
    return a
func ok(g, pos, v):
    let r = pos // 9
    let c = pos % 9
    for i in range(9):
        if g[r * 9 + i] == v or g[i * 9 + c] == v:
            return false
    let br = r - r % 3
    let bc = c - c % 3
    for i in range(3):
        for j in range(3):
            if g[(br + i) * 9 + bc + j] == v:
                return false
    return true
let nodes = 0
func solve(g, pos):
    if pos == 81:
        return true
    if g[pos] != 0:
        return solve(g, pos + 1)
    for v in range(1, 10):
        nodes += 1
        if ok(g, pos, v):
            g[pos] = v
            if solve(g, pos + 1):
                return true
            g[pos] = 0
    return false
let puzzle = "800000000003600000070090200050007000000045700000100030001000068008500010090000400"
let total = 0
for r in range(12):
    let g = fill(81, 0)
    for i in range(81):
        g[i] = puzzle[i] - 48
    solve(g, 0)
    let s = 0
    for i in range(81):
        s = s * 7 + g[i]
        s = s % 1000003
    total += s
print(total, nodes)
