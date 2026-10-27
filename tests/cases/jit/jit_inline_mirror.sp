class V:
    let x = 0
    let y = 0
    let f = 0.0
    func init(self, x, y):
        self.x = x
        self.y = y
        self.f = x * 0.5 + y * 0.25

func sq(a):
    return a * a + a

func mix(a, b):
    let t = a * b
    let u = t + a
    let w = u * b + t
    return w - a

let s = 0
let fs = 0.0
for i in range(2000):
    let v = V(i, i + 1)
    s += v.x * v.x + v.y + sq(i) + mix(i, 3)
    fs += v.f + sq(0.5)
print(s)
print(fs)
