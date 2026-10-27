import math
export const LIMIT = 10
class Counter:
    let n = 0
    func init(self, start):
        self.n = start
    func bump(self):
        self.n += 1
        return self.n
func risky(x):
    if x < 0:
        throw error("ValueError", "negative")
    return math.sqrt(x)
let c = Counter(5)
for i in range(3):
    c.bump()
print(c.n)
try:
    risky(-1)
catch e:
    print(e.kind, e.message)
let squares = [1, 2, 3].map(func(x): x * x)
match squares:
    case [first, _, _]:
        print("first =", first)
    case _:
        print("other shape")
func read(path):
    defer print("done")
    return path
print(read("p"))
