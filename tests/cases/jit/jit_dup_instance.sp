# a duplicated instance (self.count += n reads and writes self) keeps its class in the function JIT:
# polymorphic methods over several subclasses compile and give the interpreter's results
class Task:
    let count = 0
    let prio = 0
    func init(self, prio):
        self.prio = prio
    func run(self, n):
        return 0
class A extends Task:
    override func run(self, n):
        self.count += 1
        return (n * 3 + 1) % 1009
class B extends Task:
    override func run(self, n):
        self.count += 2
        return (n + self.prio) % 1013
class C extends Task:
    override func run(self, n):
        self.count += 3
        self.prio -= 1
        return (n * (self.prio + 9) + 7) % 1019
let ts = [A(1), B(2), C(3), A(4), B(5), C(6)]
let n = 1
let acc = 0
for r in range(4000):
    for t in ts:
        n = t.run(n)
        acc += n
print(acc, ts[0].count, ts[1].count, ts[2].count, ts[2].prio)
