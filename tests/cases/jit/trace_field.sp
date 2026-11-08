class P:
    let x = 0
    let y = 0
    func init(self, x, y):
        self.x = x
        self.y = y
class Q:
    let x = 100
    let y = 0
func run(k):
    let p = P(3, 4)
    let q = Q()
    let s = 0
    for i in range(k):
        p.x = p.x + 1
        q.x = q.x + p.y
        s += p.x + p.y + q.x
    return s + p.x + q.x
print(run(100000))
func alias(k):
    let p = P(1, 2)
    let q = p
    let s = 0
    for i in range(k):
        p.x = p.x + 1
        s += q.x
    return s
print(alias(100000))
func mixed(k):
    let p = P(1, 2)
    let s = 0
    for i in range(k):
        s += p.y
        if i == 50000:
            p.y = 1.5
    return s
print(mixed(100000))
