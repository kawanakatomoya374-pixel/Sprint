func make(k):
    return func(x): x + k
let live = []
for i in range(400000):
    live.append(make(i))
let s = 0
for r in range(5):
    for i in range(300000):
        let f = make(i)
        s += f(r)
for f in live:
    s += f(1)
print(s, len(live))
