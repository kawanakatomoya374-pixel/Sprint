import typed

# hot loops over typed arrays of every kind: reads, wrapping stores, int -> float stores, f32 rounding
func fill_all(n):
    let k = [typed.i8(8), typed.u8(8), typed.i16(8), typed.u16(8), typed.i32(8), typed.u32(8), typed.i64(8)]
    let f32 = typed.f32(8)
    let f64 = typed.f64(8)
    let i8 = k[0]
    let u8 = k[1]
    let i16 = k[2]
    let u16 = k[3]
    let i32 = k[4]
    let u32 = k[5]
    let i64 = k[6]
    let s = 0
    let fs = 0.0
    for i in range(n):
        let j = i % 8
        i8[j] = i * 3 - 100
        u8[j] = i * 7 + 250
        i16[j] = i * 1001 - 40000
        u16[j] = i * 70001
        i32[j] = i * 1000003 - 2000000000
        u32[j] = i * 99999989
        i64[j] = i * 1000000007 * 1000003
        f32[j] = i * 0.1
        f64[j] = i
        s = (s + i8[j] + u8[j] + i16[j] + u16[j] + i32[j] + u32[j] + i64[j] % 1000) % 1000003
        fs += f32[j] + f64[j]
    return [s, fs, i8.to_array(), u8.to_array(), i16.to_array(), u16.to_array(), i32.to_array(), u32.to_array(), i64.to_array(), f32.to_array(), f64.to_array()]
print(fill_all(2000))

# a loop that reads one array while writing another, with index expressions
func conv(src, dst, n):
    for i in range(1, n - 1):
        dst[i] = (src[i - 1] + 2 * src[i] + src[i + 1]) // 4
func run_conv():
    let src = typed.u8(1000)
    let dst = typed.u8(1000)
    for i in range(1000):
        src[i] = (i * 37) % 251
    for r in range(20):
        conv(src, dst, 1000)
        conv(dst, src, 1000)
    let t = 0
    for i in range(1000):
        t += src[i] * 3 + dst[i]
    return t
print(run_conv())

# the array in the loop changes kind part way: the compiled guard fails and the interpreter takes over
func flip(n):
    let a = typed.i32(16)
    let t = 0
    for i in range(n):
        if i == 300:
            a = typed.u8(16)
        if i == 600:
            a = typed.f64(16)
        a[i % 16] = i * 5
        t += a[(i + 3) % 16]
    return [t, a.to_array()]
print(flip(1000))

# an ordinary array swapped in, and a float into an integer array: TypeError at the same iteration
func swap(n):
    let a = typed.i64(8)
    let t = 0
    for i in range(n):
        if i == 400:
            a = [1, 2, 3, 4, 5, 6, 7, 8]
        a[i % 8] = i
        t += a[(i * 3) % 8]
    return t
print(swap(1000))
func bad_store(n):
    let a = typed.i32(8)
    let t = 0
    try:
        for i in range(n):
            if i == 500:
                a[1] = 1.5
            a[i % 8] = i
            t += a[(i + 1) % 8]
    catch e:
        print(e.kind, e.message, t)
    return a.to_array()
print(bad_store(1000))
func oob(n):
    let a = typed.f64(10)
    let t = 0.0
    try:
        for i in range(n):
            a[i % 10] = i * 0.5
            t += a[(i + 1) % 10] + a[i % 10 + i // 600]
    catch e:
        print(e.kind, e.message, t)
    return a.to_array()
print(oob(1000))

# top level (module variables)
let m = typed.f64(64)
let acc = 0.0
for i in range(5000):
    m[i % 64] = i * 0.25
    acc += m[(i + 7) % 64]
print(acc)

# allocation inside the loop (GC) and iteration of a typed array
func gc_loop(n):
    let t = 0
    for i in range(n):
        let b = typed.u16(32)
        for j in range(32):
            b[j] = i + j
        for x in b:
            t += x
    return t
print(gc_loop(300))

# one loop, compiled for the first array it sees, then called with other kinds and an ordinary array: the class guard fails
# and the interpreter takes over each time
func use(a, n):
    let t = 0
    for i in range(n):
        a[i % 8] = i * 3
        t += a[(i + 5) % 8]
    return t
let pool = [typed.i32(8), typed.i32(8), typed.u8(8), typed.i16(8), typed.f64(8), [0, 0, 0, 0, 0, 0, 0, 0], typed.i32(8), typed.f32(8), typed.i64(8)]
for k in range(len(pool)):
    print(k, use(pool[k], 500), pool[k][3])
let ok = 0
try:
    use(typed.i32(4), 500)
catch e:
    print(e.kind, e.message)
try:
    use("abc", 500)
catch e:
    print(e.kind, e.message)

# element access inside an inlined function, with operands still pending in the caller, and the array changing under it
func at(a, i):
    return a[i]
func put(a, i, v):
    a[i] = v
func inl(n, alt):
    let T = typed.f64(8)
    let U = typed.i32(8)
    let t = 0.0
    for i in range(n):
        let k = i * 0.5
        put(T, i % 8, k)
        put(U, i % 8, i)
        if i == 700:
            T = alt
        t += k + at(T, (i + 1) % 8) + at(U, (i + 3) % 8) - i
    return t
print(inl(1500, typed.f32(8)))
func inl2(n, alt):
    let A = typed.u8(8)
    let t = 0
    for i in range(n):
        let a = i
        let b = i + 1
        if i == 900:
            A = alt
        put(A, i % 8, i)
        t += a - (b + at(A, (i * 5) % 8))
    return t
print(inl2(1200, [1, 2, 3, 4, 5, 6, 7, 8]))
print(inl2(1200, typed.i16(8)))

# methods that index a field or an argument are inlined into the loop; operands stay pending below the call
class Buf:
    let d = nil
    let n = 1
    func init(self, d):
        self.d = d
    func get(self, i):
        return self.d[i]
    func put(self, i, v):
        self.d[i] = v
    func addat(self, i, v):
        self.d[i] = self.d[i] + v
        return self.d[i]
func drive(o, n, alt):
    let t = 0
    for i in range(n):
        let k = i * 2
        o.put(i % 8, i)
        t += k + o.get((i + 3) % 8) - o.addat((i + 5) % 8, 1)
        if i == 900:
            o.d = alt
    return t
for d in [typed.i32(8), typed.f64(8), typed.u8(8), [0, 0, 0, 0, 0, 0, 0, 0]]:
    print(drive(Buf(d), 1200, typed.i16(8)), drive(Buf(d), 1200, [5, 5, 5, 5, 5, 5, 5, 5]))
func drive_err(o, n):
    let t = 0
    try:
        for i in range(n):
            t += i + o.get(i % 12)
    catch e:
        print(e.kind, e.message, t)
drive_err(Buf(typed.u16(10)), 100)
drive_err(Buf([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]), 100)
