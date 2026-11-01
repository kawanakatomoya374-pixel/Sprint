let mod_sum = 0
let mul_sum = 0
let add_sum = 0
let sub_sum = 0
for i in range(1, 10001):
    mod_sum += i % 17
    mul_sum += i * 3
    add_sum += i + 5
    sub_sum += i - 4
print(mod_sum, mul_sum, add_sum, sub_sum)

func local_ops(n):
    let m = 0
    let p = 0
    let a = 0
    let s = 0
    for i in range(1, n + 1):
        m += i % 17
        p += i * 3
        a += i + 5
        s += i - 4
    return [m, p, a, s]
print(local_ops(10000))

let float_sum = 0.5
for i in range(1, 1001):
    float_sum += i % 17
print(float_sum)
