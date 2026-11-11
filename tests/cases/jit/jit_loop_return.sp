# A return, or a call in a path that ends in a return, inside a hot loop: the region leaves to the interpreter there.
func find_first(a, target):
    let n = len(a)
    let i = 0
    while true:
        if i >= n:
            return -1
        if a[i] == target:
            return i
        i += 1
let a = []
for i in range(2000):
    a.append(i * 3 % 1001)
print(find_first(a, 777), find_first(a, 5000), find_first(a, a[1999]))

func loop_print(n):
    let s = 0
    let i = 0
    while true:
        s += i * i % 13
        i += 1
        if i == n:
            print("done", s)
            return s
print(loop_print(4000))

func nested_return(m, n):
    let t = 0
    for i in range(m):
        for j in range(n):
            t += (i ^ j) & 7
            if t > 20000:
                return [i, j, t]
    return [m, n, t]
print(nested_return(100, 100))
print(nested_return(10, 10))

func method_in_cold(n):
    let out = []
    let k = 0
    while true:
        k += 1
        if k > n:
            out.append(to_string(k))
            return out.join(",") .. "!" .. str_of(len(out))
        if k % 1000 == 0:
            out.append(to_string(k))
func str_of(x):
    return to_string(x)
print(method_in_cold(5000))

func error_path(n):
    let s = 0
    for i in range(n):
        s += i
        if i == n - 1:
            return s // (n - n)
try:
    print(error_path(300))
catch e:
    print(e.kind)
