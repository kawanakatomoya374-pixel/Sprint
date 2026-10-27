class A:
    func init(self, v):
        self.v = v
    let v = 0
class B extends A:
    override func init(self, v):
        super(v)
        super(v)
try:
    B(1)
catch e:
    print(e.kind)
