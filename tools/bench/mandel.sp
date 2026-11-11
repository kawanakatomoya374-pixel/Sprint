func mandel(size):
    let inside = 0
    for py in range(size):
        let ci = 2.0 * py / size - 1.0
        for px in range(size):
            let cr = 2.0 * px / size - 1.5
            let zr = 0.0
            let zi = 0.0
            let i = 0
            while i < 50 and zr * zr + zi * zi <= 4.0:
                let t = zr * zr - zi * zi + cr
                zi = 2.0 * zr * zi + ci
                zr = t
                i += 1
            if i == 50:
                inside += 1
    return inside
print(mandel(2000))
