import math
class V:
    let x = 0.0
    let y = 0.0
    let z = 0.0
    func init(self, x, y, z):
        self.x = x
        self.y = y
        self.z = z
    func sub(self, o):
        return V(self.x - o.x, self.y - o.y, self.z - o.z)
    func add(self, o):
        return V(self.x + o.x, self.y + o.y, self.z + o.z)
    func scale(self, k):
        return V(self.x * k, self.y * k, self.z * k)
    func dot(self, o):
        return self.x * o.x + self.y * o.y + self.z * o.z
class Sphere:
    let c = nil
    let r = 0.0
    func init(self, c, r):
        self.c = c
        self.r = r
    func hit(self, o, d):
        let oc = o.sub(self.c)
        let b = oc.dot(d)
        let c = oc.dot(oc) - self.r * self.r
        let disc = b * b - c
        if disc < 0.0:
            return -1.0
        return -b - math.sqrt(disc)
let spheres = [Sphere(V(0.0, 0.0, 5.0), 1.0), Sphere(V(2.0, 0.5, 6.0), 1.2), Sphere(V(-2.0, -0.5, 4.0), 0.8), Sphere(V(0.0, -101.0, 5.0), 100.0)]
let light = V(5.0, 5.0, -2.0)
let origin = V(0.0, 0.0, 0.0)
let size = 700
let acc = 0.0
for py in range(size):
    for px in range(size):
        let d0 = V((px - size / 2) / size, (py - size / 2) / size, 1.0)
        let d = d0.scale(1.0 / math.sqrt(d0.dot(d0)))
        let best = 1e30
        let bs = nil
        for s in spheres:
            let t = s.hit(origin, d)
            if t > 0.0 and t < best:
                best = t
                bs = s
        if bs != nil:
            let p = origin.add(d.scale(best))
            let n = p.sub(bs.c)
            n = n.scale(1.0 / bs.r)
            let l = light.sub(p)
            l = l.scale(1.0 / math.sqrt(l.dot(l)))
            let k = n.dot(l)
            if k > 0.0:
                acc += k
print(math.floor(acc))
