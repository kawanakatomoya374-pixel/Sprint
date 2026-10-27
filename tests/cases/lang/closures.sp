func counter():
    let n = 0
    func inc():
        n += 1
        return n
    return inc
let c = counter()
c()
c()
print(c())
let fs = []
for i in range(3):
    fs.append(func(): i * 10)
print(fs[0](), fs[1](), fs[2]())
func defs(a, b = a + 1, ...rest):
    return [a, b, len(rest)]
print(defs(1), defs(1, 5), defs(1, 2, 3, 4))
