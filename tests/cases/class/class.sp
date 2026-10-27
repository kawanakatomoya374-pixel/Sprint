let counter = 0
func next_id():
    counter += 1
    return counter

class Point:
    let x = 0
    let y = 0
    let id = next_id()

    func init(self, x, y):
        self.x = x
        self.y = y

    func length2(self):
        return self.x * self.x + self.y * self.y

    func describe(self):
        return "Point(" .. self.x .. ", " .. self.y .. ")"

class Point3 extends Point:
    let z = 0
    let tag = "p3"

    override func init(self, x, y, z):
        super(x, y)
        self.z = z

    override func length2(self):
        return super.length2() + self.z * self.z

class Empty:
    pass

let p = Point(3, 4)
let q = Point3(1, 2, 3)
print(p.length2(), q.length2(), p.id, q.id)
print(p.describe(), q.describe(), q.tag)
print(class_name(classof(q)), is_instance(q, Point), is_instance(p, Point3), classof(5))
print(Point, type(Point), type(p))
let f = p.length2
print(f(p), Point.length2(q))
q.z = 10
print(q.z, q.length2())
let e = Empty()
print(e == e, e == Empty(), has({}, "a"))
match q:
    case {x: x, z: z}:
        print("matched", x, z)

try:
    p.nope = 1
catch err:
    print(err.kind)
try:
    print(p.nope)
catch err:
    print(err.kind)
try:
    Empty(1)
catch err:
    print(err.kind)
try:
    p.length2 = 5
catch err:
    print(err.kind)
class Acc:
    let items = []
    func add(self, v):
        self.items.append(v)
        return self
    func total(self):
        let t = 0
        for v in self.items:
            t += v
        return t
let a = Acc()
a.add(1).add(2).add(3)
print(a.total(), len(a.items), len(Acc().items))
