func counter():
    let n = 0
    func inc():
        n += 1
        return n
    return inc
func run(f, k):
    let r = 0
    for i in range(k):
        r = f()
    return r
print(run(counter(), 200000000))
