import gc
class Node:
    let val=0
    let next=nil
    func init(self,v,n):
        self.val=v
        self.next=n
let keep=[]
let total=0
for round in range(2000):
    let head=nil
    for i in range(5000):
        head=Node(i,head)
    let p=head
    while p!=nil:
        total+=p.val
        p=p.next
    let t={}
    for i in range(500):
        t["k"..i]=[i,i+1]
    total+=len(t)
    if round%200==0:
        keep.append(head)
let s=gc.stats()
print(total,len(keep),s.collections)
