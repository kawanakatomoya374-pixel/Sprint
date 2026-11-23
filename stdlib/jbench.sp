# jbench: a few small programs that exercise the JIT (integer loops, recursion, objects, arrays, floats, strings). run(clock) times each with clock() -> milliseconds
# and returns [[name, ms]]. Used on the host, in the SprintOS kernel (kbench) and in a SprintOS user process (os/user/jbench.sp) to check that the JIT is fully on there.
func fib(n):
    if n < 2:
        return n
    return fib(n - 1) + fib(n - 2)

class P:
    let x = 0
    func init(self, x):
        self.x = x
    func add(self, d):
        self.x += d
        return self.x

func objs(n):
    let p = P(1)
    let s = 0
    for i in range(n):
        s += p.add(i & 3)
    return s

func arr(n):
    let a = []
    for i in range(n):
        a.append(i * 2)
    let s = 0
    for v in a:
        s += v
    return s

func flt(n):
    let x = 0.0
    for i in range(n):
        x += i * 0.5
    return x

func ints(n):
    let s = 0
    for i in range(n):
        s += i % 7
    return s

func strs(n):
    let parts = []
    for i in range(n):
        parts.append("x" .. to_string(i & 15))
    return parts.join("").count("x")

func tabs(n):
    let d = {}
    for i in range(n):
        d[to_string(i & 255)] = i
    let s = 0
    for i in range(n):
        s += d[to_string(i & 255)]
    return s

export func run(clock):
    let out = []
    let cases = [["ints 20M", () => ints(20000000)], ["fib(30)", () => fib(30)], ["objects 5M", () => objs(5000000)], ["arrays 2M", () => arr(2000000)],
                 ["floats 10M", () => flt(10000000)], ["strings 300k", () => strs(300000)], ["tables 300k", () => tabs(300000)]]
    for c in cases:
        let t0 = clock()
        c[1]()
        out.append([c[0], clock() - t0])
    return out
