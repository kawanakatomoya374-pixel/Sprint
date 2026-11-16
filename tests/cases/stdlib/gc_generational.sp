# Generational collector: objects that survived a collection are old; storing a young object into an old one must keep it alive through
# the following (minor) collections. Every container kind is exercised: arrays, tables, instance fields, closure cells, coroutine
# stacks, error chains. The garbage churn between the stores forces many collections.
import gc
import coroutine
class Box:
    let v = nil
    func init(self, v):
        self.v = v
func churn(n):
    let junk = nil
    for i in range(n):
        junk = [i, [i + 1, [i + 2]]]
    return junk
# old containers: made, then forced into the old generation
let arr = []
let tab = {}
let box = Box(nil)
let counter = 0
func bump(x):
    counter = x
    return counter
let cell_user = func(x): bump(x)
for i in range(8):
    arr.append(nil)
gc.collect()
churn(2000)
for round in range(60):
    # young objects stored into old containers
    arr[round % 8] = [round, "s" .. round, {k: round}]
    tab["k" .. (round % 5)] = Box([round, round * 2])
    box.v = ["field", round, [round]]
    cell_user([round, round + 1])
    churn(3000)
    if round % 20 == 19:
        gc.collect()
        churn(1000)
let sum = 0
for i in range(8):
    let e = arr[i]
    sum += e[0] + len(e[1]) + e[2].k
for k, b in tab:
    sum += b.v[0] + b.v[1]
sum += box.v[1] + box.v[2][0] + counter[0] + counter[1]
print(sum)
# a coroutine that ran (and so was written to) after it became old
func body():
    let local = [1, 2, 3]
    for i in range(5):
        local = [i, local]
        yield local
    return "done"
let co = coroutine.create(body)
let seen = 0
gc.collect()
for i in range(5):
    churn(2500)
    let v = coroutine.resume(co)
    seen += v[0]
    churn(2500)
print(seen, coroutine.status(co))
# errors chained into an old error
let errs = []
for i in range(30):
    try:
        throw error("E", "m" .. i)
    catch e:
        errs.append(e)
    churn(800)
gc.collect()
let msgs = 0
for e in errs:
    msgs += len(e.message)
print(msgs)
# a long array filled with young objects while it is old
let big = []
for i in range(4000):
    big.append(Box([i]))
    if i % 500 == 0:
        gc.collect()
    churn(10)
let total = 0
for b in big:
    total += b.v[0]
print(total, len(big))
