# prepared ffi calls compiled into loops (stencils ff_*): the compiled code must behave exactly like the interpreter,
# including when its guards fail (another callee, another argument type, an error)
import ffi
ffi.cdef("double sqrt(double x); double floor(double x); int abs(int x); long labs(long x); double pow(double x, double y); void srand(unsigned int s);")
let c = ffi.open(nil)
let sqrt = c.fn("sqrt")
let floor = c.fn("floor")
let abs = c.fn("abs")
let labs = c.fn("labs")
let pow = c.fn("pow")

func sum_sqrt(n):
    let s = 0.0
    for i in range(n):
        s += sqrt(to_float(i))
    return s
print(sum_sqrt(3000))

# int arguments are accepted for double parameters
func sum_sqrt_int(n):
    let s = 0.0
    for i in range(n):
        s += sqrt(i)
    return s
print(sum_sqrt_int(3000))

# a narrow signed result is sign-extended; a long stays 64-bit
func sum_abs(n):
    let s = 0
    for i in range(n):
        s += abs(0 - i) + labs(0 - i * 1000000007)
    return s
print(sum_abs(3000))

# two integer-class and two float-class arguments in registers
func sum_pow(n):
    let s = 0.0
    for i in range(n):
        s += pow(2.0, i % 10)
    return s
print(sum_pow(3000))

# the callee variable is rebound while the loop is hot: the guard must send the call to the new function
let f = sqrt
func run_swap(n):
    let s = 0.0
    for i in range(n):
        if i == n // 2:
            f = floor
        s += f(2.5 + i)
    return s
print(run_swap(3000))

# an argument whose type changes mid-loop: a string is an error, reported by the interpreter after the compiled code left
func run_err(n):
    let s = 0.0
    let arg = 4.0
    for i in range(n):
        if i == n - 1:
            arg = "x"
        s += sqrt(arg)
    return s
try:
    run_err(3000)
catch e:
    print(e.kind)

# a float where an int parameter is declared is an error too
func run_err2(n):
    let s = 0
    for i in range(n):
        s += labs(1.5 if i == n - 1 else i)
    return s
try:
    run_err2(3000)
catch e:
    print(e.kind)

# void results are nil
func run_void(n):
    let last = 1
    for i in range(n):
        last = c.fn("srand")(i)
    return last
print(run_void(300))
