func fill(n):
    let a = []
    for i in range(n):
        a.append(false)
    for i in range(n):
        if i % 3 == 0:
            a[i] = true
        else:
            a[i] = false
    for i in range(n):
        let v = i * 2
        if i % 5 == 0:
            a[i] = v
    return [a[0], a[1], a[3], a[5], a[n - 1]]
print(fill(1000))
