# Instance allocation done inline by compiled code: classes with defaults, no fields, many fields (the helper path),
# objects kept alive across collections, and the same results as the interpreter.
class Empty:
    func tag(self):
        return 7
class Dflt:
    let a = 5
    let b = 2.5
    let c = "s"
    let d = nil
    func init(self, x):
        self.d = x
class Big:
    let f0 = 0
    let f1 = 1
    let f2 = 2
    let f3 = 3
    let f4 = 4
    let f5 = 5
    let f6 = 6
    let f7 = 7
    let f8 = 8
    let f9 = 9
    let f10 = 10
    let f11 = 11
    let f12 = 12
    let f13 = 13
    let f14 = 14
    let f15 = 15
    func init(self, v):
        self.f15 = v
class Node:
    let val = 0
    let next = nil
    func init(self, v, n):
        self.val = v
        self.next = n

func build(n):
    let head = nil
    let s = 0
    for i in range(n):
        head = Node(i, head)
        let e = Empty()
        let d = Dflt(i)
        s += e.tag() + d.a + d.d
        if i % 100 == 0:
            let b = Big(i)
            s += b.f15 + b.f0 + b.f14
    let c = 0
    let p = head
    while p != nil:
        c += p.val
        p = p.next
    return [s, c]
print(build(5000))

func churn(n):
    let s = 0
    for i in range(n):
        let d = Dflt(i)
        let e = Dflt(i + 1)
        s += d.d * 2 - e.d
    return s
print(churn(200000))
