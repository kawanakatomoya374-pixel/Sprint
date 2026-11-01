func value(i):
    return i * 2 + 1
func calc(n):
    let sum = 0
    let diff = 0
    for i in range(1, n + 1):
        sum += value(i)
        diff -= value(i)
    return [sum, diff]
func float_case(x):
    let a = 0.5
    a += value(x)
    return a
print(calc(10000))
print(float_case(4))
