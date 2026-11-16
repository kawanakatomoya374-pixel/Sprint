# a call result is compiled for the type it was first seen to return; when compiled code has to leave right after a call because the
# result has another type, the next compile uses the type the call returned (float, bool). Results must equal the interpreter's whichever
# type each class returns, including a method that returns different types for different receivers.
class A:
    let x = 0.0
    func init(self, x):
        self.x = x
    func v(self):
        return self.x * 2.0
    func ok(self):
        return self.x > 2.0
class B:
    let x = 0.0
    func init(self, x):
        self.x = x
    func v(self):
        return self.x + 0.5
    func ok(self):
        return self.x > 5.0
class C:
    let n = 0
    func init(self, n):
        self.n = n
    func v(self):
        return self.n * 3
    func ok(self):
        return self.n > 4
let objs = []
for i in range(30):
    let k = i % 3
    if k == 0:
        objs.append(A(1.0 + i % 4))
    elif k == 1:
        objs.append(B(2.0 + i % 5))
    else:
        objs.append(C(i % 7))
let sf = 0.0
let cnt = 0
for r in range(3000):
    for o in objs:
        sf += o.v()
        if o.ok():
            cnt += 1
print(sf, cnt)
# only floats, only bools
let fl = [A(1.5), A(2.5), B(3.5), B(0.25)]
let t = 0.0
for r in range(5000):
    for o in fl:
        t += o.v() - 1.0
print(t)
