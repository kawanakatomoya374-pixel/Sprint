import math
func run(n):
    let a1 = 0.0
    let a2 = 0.0
    let a3 = 0.0
    let a4 = 0.0
    let a5 = 0.0
    let a6 = 0.0
    let a7 = 0.0
    let a8 = 0.0
    let a9 = 0.0
    let k = 1.0
    let sgn = 1.0
    for i in range(n):
        let k2 = k * k
        let k3 = k2 * k
        let sk = math.sin(k)
        let ck = math.cos(k)
        a1 += math.exp(0.0 - k / 4096.0)
        a2 += 1.0 / math.sqrt(k)
        a3 += 1.0 / (k * (k + 1.0))
        a4 += 1.0 / (k3 * sk * sk)
        a5 += 1.0 / (k3 * ck * ck)
        a6 += 1.0 / k
        a7 += 1.0 / k2
        a8 += sgn / k
        a9 += sgn / (2.0 * k - 1.0)
        sgn = 0.0 - sgn
        k += 1.0
    return a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8 + a9
print(math.floor(run(8000000) * 1000000))
