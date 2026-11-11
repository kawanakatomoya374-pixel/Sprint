class Circle:
    let r = 0.0
    func init(self, r):
        self.r = r
    func area(self):
        return 3.0 * self.r * self.r
class Rect:
    let w = 0.0
    let h = 0.0
    func init(self, w, h):
        self.w = w
        self.h = h
    func area(self):
        return self.w * self.h
class Tri:
    let b = 0.0
    let h = 0.0
    func init(self, b, h):
        self.b = b
        self.h = h
    func area(self):
        return 0.5 * self.b * self.h
let shapes = []
for i in range(3000):
    let k = i % 3
    if k == 0:
        shapes.append(Circle(1.0 + i % 5))
    elif k == 1:
        shapes.append(Rect(1.0 + i % 4, 2.0))
    else:
        shapes.append(Tri(3.0, 1.0 + i % 7))
let total = 0.0
for r in range(2000):
    for s in shapes:
        total += s.area()
print(total)
