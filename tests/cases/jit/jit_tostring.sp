# to_string(x) inside compiled loops for every kind of value, including an instance with its own to_string (user code runs, so
# the compiled code must hand that call to the interpreter)
class P:
    let v = 0
    func init(self, v):
        self.v = v
    func to_string(self):
        return "P<" .. to_string(self.v) .. ">"

func conv(n):
    let acc = []
    let i = 0
    while i < n:
        let k = i % 7
        if k == 0:
            acc.append(to_string(i))
        elif k == 1:
            acc.append(to_string(i * 0.5))
        elif k == 2:
            acc.append(to_string(i % 2 == 0))
        elif k == 3:
            acc.append(to_string(nil))
        elif k == 4:
            acc.append(to_string("s" .. to_string(i)))
        elif k == 5:
            acc.append(to_string([i, i + 1]))
        else:
            acc.append(to_string(P(i)))
        i += 1
    return acc

let r = conv(3000)
print(len(r), r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[2999])
let total = 0
for s in r:
    total += len(s)
print(total)

func numbers(n):
    let t = 0
    let i = 0
    while i < n:
        t = t + len(to_string(i * 7919)) + len(to_string(0 - i))
        i += 1
    return t
print(numbers(20000))
