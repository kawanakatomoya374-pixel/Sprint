# TraceJIT's guarded integer-loop tier: comparisons, loop-carried locals and deoptimization.
func up(n):
    let i = 0
    let s = 0
    while i < n:
        s += i * 2 + 1
        i += 1
    return s

func down(n):
    let i = n
    let s = 0
    while i > 0:
        s += i
        i -= 1
    return s

func le(n):
    let i = 0
    let s = 0
    while i <= n:
        s += i
        i += 1
    return s

func ge(n):
    let i = n
    let s = 0
    while i >= 1:
        s += i
        i -= 1
    return s

func ne(n):
    let i = 0
    let s = 0
    while i != n:
        s += i
        i += 1
    return s

func overflow_after_hot(n):
    let i = 0
    let x = 9223372036854775805
    while i < n:
        x += 1
        i += 1
    return x

print(up(1000))
print(down(1000))
print(le(1000))
print(ge(1000))
print(ne(1000))
# A float argument misses the integer trace guard and must use the normal VM/JIT path.
print(up(10.5))
try:
    overflow_after_hot(6)
catch e:
    print(e.kind, e.message)

# Adjacent loops in one prototype exercise TraceLinking on the second call.
func linked(n):
    let i = 0
    let split = n
    let limit = n * 2
    let a = 0
    let b = 0
    while i < split:
        a += i
        i += 1
    while i < limit:
        b += i
        i += 1
    return a + b

print(linked(10000))
print(linked(10000))

# The second trace specializes x as an integer.  On the third call the first
# trace links to it, its entry guard must fail, and the VM resumes at its header.
func linked_guard(n, x):
    let i = 0
    let j = 0
    while i < n:
        i += 1
    while j < n:
        x += 1
        j += 1
    return x

print(linked_guard(100, 0))
print(linked_guard(100, 0))
print(linked_guard(100, 0.0))
