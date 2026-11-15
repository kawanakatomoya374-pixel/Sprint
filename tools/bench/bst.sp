class Node:
    let key = 0
    let left = nil
    let right = nil
    func init(self, k):
        self.key = k
class Tree:
    let root = nil
    let size = 0
    func insert(self, k):
        if self.root == nil:
            self.root = Node(k)
            self.size += 1
            return
        let cur = self.root
        while true:
            if k < cur.key:
                if cur.left == nil:
                    cur.left = Node(k)
                    self.size += 1
                    return
                cur = cur.left
            elif k > cur.key:
                if cur.right == nil:
                    cur.right = Node(k)
                    self.size += 1
                    return
                cur = cur.right
            else:
                return
    func has(self, k):
        let cur = self.root
        while cur != nil:
            if k < cur.key:
                cur = cur.left
            elif k > cur.key:
                cur = cur.right
            else:
                return true
        return false
func height(n):
    if n == nil:
        return 0
    let l = height(n.left)
    let r = height(n.right)
    return 1 + (l if l > r else r)
let t = Tree()
let seed = 13
for i in range(200000):
    seed = (seed * 16807) % 2147483647
    t.insert(seed % 1000000)
let hits = 0
for i in range(400000):
    seed = (seed * 16807) % 2147483647
    if t.has(seed % 1000000):
        hits += 1
print(t.size, hits, height(t.root))
