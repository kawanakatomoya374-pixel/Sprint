class C:
    let v = 1
    func init(self, v):
        self.v = v
    func get(self):
        return self.v + 1
    func twin(self):
        return C(self.v + 1)

let o = C(1)
let total = 0

func rec(n):
    let s = 0
    for i in range(4):
        s += o.get() + o.twin().get()
    total += s
    if n > 0:
        return rec(n - 1) + 1
    return 0

print(rec(50))
print(total)
# deep recursion right up to the call-depth limit: loops that cannot be entered (no room for the inlined frames) just run in the interpreter
total = 0
print(rec(1018))
print(total)
