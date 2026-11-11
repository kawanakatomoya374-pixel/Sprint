func fill(n, v):
    let a = []
    a.reserve(n)
    for i in range(n):
        a.append(v)
    return a
func factorial_digits(n):
    let d = fill(9000, 0)
    d[0] = 1
    let len_d = 1
    for m in range(2, n + 1):
        let carry = 0
        for i in range(len_d):
            let v = d[i] * m + carry
            d[i] = v % 10000
            carry = v // 10000
        while carry > 0:
            d[len_d] = carry % 10000
            carry = carry // 10000
            len_d += 1
    let s = 0
    for i in range(len_d):
        s += d[i]
    return s
print(factorial_digits(9000))
