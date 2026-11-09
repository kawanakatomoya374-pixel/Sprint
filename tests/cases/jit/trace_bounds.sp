func sum_ok(a, n):
    let s = 0
    for k in range(3):
        for i in range(n):
            s += a[i]
    return s
let arr = [1, 2, 3, 4, 5, 6, 7, 8]
print(sum_ok(arr, 8))
print(sum_ok(arr, 4))
func nested(m, n):
    let t = 0
    for r in range(len(m)):
        let row = m[r]
        for c in range(n):
            t += row[c] * (c + 1)
    return t
let mm = [[1, 2, 3], [4, 5, 6], [7, 8, 9]]
print(nested(mm, 3))
print(nested(mm, 2))
func neg(a):
    let s = 0
    for rep in range(200):
        for i in range(-2, 3):
            s += a[i]
    return s
try:
    print(neg(arr))
catch err:
    print(err.kind)
func big(a, n):
    let s = 0
    for rep in range(200):
        for i in range(n):
            s += a[i]
    return s
print(big(arr, 8))
try:
    print(big(arr, 9))
catch err:
    print(err.kind)
print(big(arr, 8))
