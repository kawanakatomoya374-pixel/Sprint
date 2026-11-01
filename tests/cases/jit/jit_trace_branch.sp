# conditional branches inside trace-compiled loops: the trace follows the observed direction and leaves through a deopt exit
# when a later iteration goes the other way; every result must equal the interpreter's
func parity(n):
    let a = 0
    let b = 0
    let i = 0
    while i < n:
        if i % 2 == 0:
            a = a + i
        else:
            b = b + i * 3
        i += 1
    return [a, b]
print(parity(5000))

# a branch that is always the same way until the very end
func late_flip(n):
    let s = 0
    let i = 0
    while i < n:
        if i < n - 3:
            s = s + 1
        else:
            s = s + 1000
        i += 1
    return s
print(late_flip(5000))

# collatz: the data-dependent branch flips constantly
func collatz(n):
    let steps = 0
    while n != 1:
        if n % 2 == 0:
            n = n // 2
        else:
            n = 3 * n + 1
        steps += 1
    return steps
let best = 0
let k = 1
while k < 2000:
    let c = collatz(k)
    if c > best:
        best = c
    k += 1
print(best)

# branches on a comparison of two locals, and an inverted test
func clamp_sum(n, lo, hi):
    let s = 0
    let i = 0
    while i < n:
        let v = (i * 7) % 100
        if v < lo:
            s = s + lo
        elif v > hi:
            s = s + hi
        else:
            s = s + v
        i += 1
    return s
print(clamp_sum(5000, 20, 80))

# a branch that skips the rest of the body (forward jump)
func skip(n):
    let s = 0
    let i = 0
    while i < n:
        i += 1
        if i % 3 == 0:
            s = s + 100
        if i % 5 != 0:
            s = s + 1
    return s
print(skip(5000))

# the loop condition itself is a branch that is not the first thing of the iteration
func tail_test(n):
    let s = 0
    let i = 0
    while i < n:
        s = s + i
        i += 1
        if s > 1000000000:
            s = 0
    return s
print(tail_test(5000))

# an error raised by the interpreter after a deopt (division by zero reached through a branch)
func div_branch(n):
    let s = 0
    let i = 0 - n
    while i < n:
        if i != 0:
            s = s + 1000 // i
        i += 1
    return s
print(div_branch(2000))
