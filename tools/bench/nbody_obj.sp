import math
class Body:
    let x = 0.0
    let y = 0.0
    let z = 0.0
    let vx = 0.0
    let vy = 0.0
    let vz = 0.0
    let mass = 0.0
    func init(self, x, y, z, vx, vy, vz, mass):
        self.x = x
        self.y = y
        self.z = z
        self.vx = vx
        self.vy = vy
        self.vz = vz
        self.mass = mass
let bodies = [
    Body(0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 39.47),
    Body(4.84, -1.16, -0.10, 0.606, 2.81, -0.02, 0.037),
    Body(8.34, 4.12, -0.4, -1.01, 1.82, 0.008, 0.011),
    Body(12.89, -15.11, -0.22, 1.08, 0.868, -0.01, 0.0017),
    Body(15.37, -25.9, 0.179, 0.979, 0.594, -0.034, 0.002)]
func advance(bs, dt):
    let n = len(bs)
    for i in range(n):
        let bi = bs[i]
        for j in range(i + 1, n):
            let bj = bs[j]
            let dx = bi.x - bj.x
            let dy = bi.y - bj.y
            let dz = bi.z - bj.z
            let d2 = dx * dx + dy * dy + dz * dz
            let mag = dt / (d2 * math.sqrt(d2))
            bi.vx -= dx * bj.mass * mag
            bi.vy -= dy * bj.mass * mag
            bi.vz -= dz * bj.mass * mag
            bj.vx += dx * bi.mass * mag
            bj.vy += dy * bi.mass * mag
            bj.vz += dz * bi.mass * mag
    for b in bs:
        b.x += dt * b.vx
        b.y += dt * b.vy
        b.z += dt * b.vz
for i in range(300000):
    advance(bodies, 0.01)
print(to_int(bodies[0].x * 100000), to_int(bodies[1].y * 100000))
