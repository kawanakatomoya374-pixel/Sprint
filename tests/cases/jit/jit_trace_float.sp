# Guarded floating-point TraceJIT coverage: arithmetic, comparisons and deopt.
func calc(n):
    let i = 0.0
    let total = 0.0
    while i < n:
        total += (i * 0.5) + 1.0
        i += 1.0
    return total

func descend(n):
    let i = n
    let total = 0.0
    while i >= 1.0:
        total += i / 2.0
        i -= 1.0
    return total

func mixed_const(n):
    let i = 0.0
    let total = 0.0
    while i != n:
        total += i + 2
        i += 1.0
    return total

print(calc(1000.0))
print(descend(1000.0))
print(mixed_const(1000.0))
