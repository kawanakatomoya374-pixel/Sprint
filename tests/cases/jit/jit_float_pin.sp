# float locals carried across the iterations of an innermost loop (kept in registers by the region JIT)
func mandel_row(size, py):
    let inside = 0
    let ci = 2.0 * py / size - 1.0
    for px in range(size):
        let cr = 2.0 * px / size - 1.5
        let zr = 0.0
        let zi = 0.0
        let i = 0
        while i < 40 and zr * zr + zi * zi <= 4.0:
            let t = zr * zr - zi * zi + cr
            zi = 2.0 * zr * zi + ci
            zr = t
            i += 1
        if i == 40:
            inside += 1
    return inside

func mixed(n):
    let a = 0.0
    let b = 1.0
    let c = 0.5
    let k = 0
    while k < n:
        if k % 3 == 0:
            a = a + b * c
        else:
            b = b + 0.25
        c = c * 0.999 + a * 0.0001
        k += 1
    return [a, b, c]

func type_switch(n):
    let x = 1.5
    let y = 0.0
    let k = 0
    while k < n:
        y += x
        if k == n - 3:
            x = 2
        k += 1
    return [x, y]

func swap_loop(n):
    let p = 1.0
    let q = 2.0
    let k = 0
    while k < n:
        let t = p
        p = q
        q = t + q * 0.01
        k += 1
    return [p, q]

func with_div(n):
    let s = 0.0
    let d = 1.0
    let k = 0
    while k < n:
        s += 1.0 / d
        d += 1.0
        k += 1
    return s

let tot = 0
for r in range(30):
    tot += mandel_row(60, r * 2)
print(tot)
for r in range(3):
    print(mixed(500 + r))
    print(type_switch(40 + r))
    print(swap_loop(300 + r))
    print(with_div(1000 + r))
