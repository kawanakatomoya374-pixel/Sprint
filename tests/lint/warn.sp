import gfx
import math   # unused


   # leading comment
let a=1+2*3   #trailing
let t = {x:1,y : 2, "x":3}
func  f( a,b=2 ,...rest ):
    let unused = 5
    if a>b and not (a==b):
        return -a
        print("dead")
    elif a<b :
        return [1,2 , 3][0:2]
    # comment in block
    return f (a)  .name



class Foo extends Bar :
    let x=0
    override func init(self,x):
        super (x)
        self.x+=x**2
x = f"a{ 1 }" ..  "b"
let s = """keep   
   this  """   # c
call(a,
  b,
        c)
#* block
   keep me
*#
let z = a if b else -c
try:
    pass
catch e:
    pass
