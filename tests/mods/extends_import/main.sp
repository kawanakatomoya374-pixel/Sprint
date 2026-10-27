import base.shapes as sh
from base.shapes import Named, Plain

class Square extends sh.Shape:
    let side = 3
    override func init(self, side):
        super("square", 4)
        self.side = side
    override func area(self):
        return self.side * self.side
    override func describe(self):
        return "Square:" .. super.describe()

class Cube extends Square:
    let depth = 2
    override func area(self):
        return super.area() * 6

class Tagged extends Named:
    let n = 1

class Quiet extends Plain:
    let v = 5
    func get(self):
        return self.v

class NoInit extends sh.Shape:
    let extra = "x"

let s = Square(4)
print(s.area(), s.describe(), s.scale, s.pts, s.tag, s.base_n, s.hello())
let c = Cube(2)
print(c.area(), c.depth, c.describe())
let t = Tagged()
print(t.show(), t.label, t.n)
t.label = "x"
print(t.show())
print(Quiet().get(), Quiet().v)
let ni = NoInit("ni", 9)
print(ni.describe(), ni.extra)
let a = Square(1)
let b = Square(2)
a.pts.append(1)
print(len(a.pts), len(b.pts), len(s.pts))
print(is_instance(s, sh.Shape), is_instance(c, Square), is_instance(c, sh.Shape), is_instance(t, Named), is_instance(s, Named))
