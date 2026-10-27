import typed

# creation: a length or an array
let a = typed.i32(4)
print(len(a), a.to_array(), a.kind(), type(a))
let b = typed.u8([1, 2, 255, 256, 300, -1])
print(b.to_array())
let c = typed.f64([1, 2.5, 3])
print(c.to_array())
print(typed.f32([0.1, 1e40, -1e40]).to_array())
print(typed.i8([127, 128, 200, -129]).to_array())
print(typed.u16([65535, 65536, -1]).to_array())
print(typed.i16([32767, 32768]).to_array())
print(typed.u32([4294967295, 4294967296, -1]).to_array())
print(typed.i32([2147483647, 2147483648]).to_array())
print(typed.i64([9223372036854775807, -9223372036854775807 - 1]).to_array())
print(typed.i32(0).to_array(), len(typed.f64(0)))

# element read / write
a[0] = 10
a[3] = -7
print(a[0], a[1], a[3], type(a[0]), type(typed.f32(1)[0]))
let f = typed.f64(3)
f[0] = 2
f[1] = 0.5
print(f[0], f[1], f[2], type(f[0]))

# for-in
let s = 0
for x in typed.u8([1, 2, 3, 250]):
    s += x
print(s)
for x in typed.f64(0):
    print("never")

# methods
let d = typed.u8([5, 6, 7, 8, 9])
print(d.slice(1, 3).to_array(), d.slice(2).to_array(), d.slice(5).to_array(), d.copy().to_array())
let e = d.copy()
e.fill(300)
print(e.to_array(), d.to_array())
let g = typed.i32(6)
g.set_from([1, 2, 3], 2)
g.set_from(typed.u8([9, 8]), 0)
print(g.to_array())
let h = typed.f64(4)
h.set_from(typed.f32([0.5, 0.25]), 1)
print(h.to_array())
let o = typed.u8(4)
o.set_from(typed.u8([1, 2, 3, 4]), 0)
o.set_from(o.slice(0, 3), 1)
print(o.to_array())
print(typed.f64(2).fill(1.5), d == d, d == d.copy())

# errors
func err(f):
    try:
        f()
    catch e:
        print(e.kind, e.message)
func put(arr, i, v):
    arr[i] = v
let t8 = typed.u8(3)
err(func(): t8[3])
err(func(): t8[-1])
err(func(): t8["a"])
err(func(): put(t8, 0, 1.5))
err(func(): put(t8, 0, true))
err(func(): put(t8, 0, nil))
err(func(): put(typed.f64(2), 0, "x"))
err(func(): put(t8, 3, 1))
err(func(): put(t8, "k", 1))
err(func(): typed.i32(-1))
err(func(): typed.i32("x"))
err(func(): typed.u8(1 << 40))
err(func(): t8.slice(2, 1))
err(func(): t8.slice(0, 4))
err(func(): t8.set_from([1, 2], 2))
err(func(): t8.set_from([1], -1))
err(func(): t8.set_from("ab", 0))
err(func(): t8.fill(2.5))
err(func(): typed.u8(0).fill(nil))
err(func(): typed.u8([1, 2, 1.5]))
err(func(): len(5))

# for i, x in
for i, x in typed.f32([0.5, 1.5]):
    print(i, x)
