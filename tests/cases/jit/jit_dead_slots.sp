# Body-local lets are dead at the loop header: traces keep no state for them, results must match the interpreter.
func f(n):
    let acc = 0
    let last = 0
    for i in range(n):
        let a = i * 2
        let b = a + 1
        if i % 3 == 0:
            let c = b * 2
            acc = acc + c
        else:
            acc = acc + b
        last = b
    return [acc, last]

func g(n):
    let s = 0.0
    let t = 0
    let i = 0
    while i < n:
        let x = i * 0.5
        let y = x + 1.0
        s = s + y
        t = i
        i = i + 1
    return [s, t]
print(f(3000))
print(g(3000))
