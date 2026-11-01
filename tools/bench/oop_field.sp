class P:
    let x = 0
    let y = 0
    func init(self, x, y):
        self.x = x
        self.y = y
    func add(self, o):
        return P(self.x + o.x, self.y + o.y)
    func len2(self):
        return self.x * self.x + self.y * self.y
func run(k):
    let p = P(3, 4)
    let s = 0
    for i in range(k):
        s += p.x + p.y
    return s
print(run(50000000))
