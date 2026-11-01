func local_store(n):
    let a = 0
    let s = 0
    for i in range(1, n + 1):
        a = i + 7
        s = i - 3
    return [a, s]
func float_fallback(x):
    let y = 0
    y = x + 7
    return y
print(local_store(10000))
print(float_fallback(0.5))
