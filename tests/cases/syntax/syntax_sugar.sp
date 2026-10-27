# arrow lambdas
let inc = x => x + 1
let add = (a, b = 10) => a + b
let k = () => 42
print(inc(1), add(1), add(1, 2), k())
let curry = a => b => a * b
print(curry(3)(4))
# pipe
func double(x):
    return x * 2
func plus(x, n):
    return x + n
print(5 |> double)
print(5 |> plus(3) |> double)
print([3, 1, 2] |> len)
print("x" |> (s => s .. s))
let r = [1, 2, 3].map(x => x * x)
print(r)
# comprehensions
print([x * 2 for x in [1, 2, 3]])
print([x for x in range(10) if x % 2 == 0])
print([[i, j] for i in range(3) for j in range(i)])
print([[y + 1 for y in row] for row in [[1, 2], [3]]])
let t = {k: k .. "!" for k in ["a", "b"]}
print(t.a, t.b, len(t))
print({i: i * i for i in range(4) if i > 0})
print(len([x for x in []]))
func capt(n):
    return [() => i + n for i in range(3)]
print(capt(10).map(f => f()))
print(plus(1, len([x for x in range(3)])))
# for filter
let total = 0
for x in [1, 2, 3, 4, 5, 6] if x % 2 == 0:
    total += x
print(total)
for x in [1, 2] if true else [3]:
    print("cond", x)
let big = [i for i in range(100000)]
print(len(big))
func inc2(x):
    return x + 1
let v = 1
    |> inc2
    |> inc2
print(v)
if v == 3:
    let w = v
        |> inc2
    print(w)
