class Task:
    let id = 0
    let prio = 0
    let count = 0
    let state = 0
    func init(self, id, prio):
        self.id = id
        self.prio = prio
    func run(self, n):
        return 0
class Idle extends Task:
    override func run(self, n):
        self.count += 1
        return (n * 3 + 1) % 1009
class Worker extends Task:
    override func run(self, n):
        self.count += 2
        return (n + self.prio) % 1013
class Handler extends Task:
    override func run(self, n):
        self.count += 3
        return (n * self.prio + 7) % 1019
class Device extends Task:
    override func run(self, n):
        self.count += 1
        return n ^ self.id
let tasks = []
for i in range(40):
    let k = i % 4
    if k == 0:
        tasks.append(Idle(i, i % 5))
    elif k == 1:
        tasks.append(Worker(i, i % 7))
    elif k == 2:
        tasks.append(Handler(i, i % 3 + 1))
    else:
        tasks.append(Device(i, i % 2))
let acc = 0
let n = 1
for r in range(120000):
    for t in tasks:
        n = t.run(n)
        acc += n
print(acc, tasks[0].count, tasks[5].count)
