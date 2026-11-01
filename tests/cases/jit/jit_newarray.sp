# array literals inside compiled loops: empty, with elements, nested, kept alive across allocations (GC) and mutated afterwards
func build(n):
    let rows = []
    let i = 0
    while i < n:
        let row = []
        let j = 0
        while j < 3:
            row.append(i * 10 + j)
            j += 1
        rows.append(row)
        i += 1
    return rows
let r = build(2000)
print(len(r), r[0], r[1999], len(r[7]))

func pairs(n):
    let out = []
    let i = 0
    while i < n:
        out.append([i, i * 2, [i % 3, "x"]])
        i += 1
    return out
let p = pairs(3000)
print(len(p), p[2999][0], p[2999][1], p[2999][2][0], p[2999][2][1], p[5])

func churn(n):
    let keep = []
    let sum = 0
    let i = 0
    while i < n:
        let tmp = [i, i + 1, i + 2, [i]]
        sum = sum + tmp[0] + tmp[3][0]
        if i % 100 == 0:
            keep.append(tmp)
        i += 1
    return [sum, len(keep), keep[3][2]]
print(churn(20000))

func independent(n):
    let a = []
    let b = []
    let i = 0
    while i < n:
        a = [i]
        b = [i]
        a.append(7)
        i += 1
    return [a, b]
print(independent(1000))
