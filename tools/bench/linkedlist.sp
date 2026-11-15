class Cell:
    let v = 0
    let next = nil
    func init(self, v, n):
        self.v = v
        self.next = n
func build(n):
    let h = nil
    for i in range(n):
        h = Cell(i, h)
    return h
func reverse(h):
    let prev = nil
    while h != nil:
        let nx = h.next
        h.next = prev
        prev = h
        h = nx
    return prev
func sum(h):
    let s = 0
    while h != nil:
        s += h.v
        h = h.next
    return s
let total = 0
for r in range(40):
    let l = build(50000)
    l = reverse(l)
    total += sum(l)
    l = reverse(l)
    total += l.v
print(total)
