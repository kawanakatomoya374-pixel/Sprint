# Constant modulo may use a branchless pinned-register path only when a positive unit range
# is the sole writer of the pinned local. Negative starts must leave the fast path until >= 0.
let up = 0
for i in range(-1200, 1200, 1):
    up += i % 7
print(up)

let down = 0
for j in range(1200, -1200, -1):
    down += j % 7
print(down)

# Writing the range variable in the body must disable the nonnegative proof.
let changed = 0
for k in range(0, 5000, 1):
    k = k - 2
    changed += k % 7
print(changed)

# Unit-step loops adjacent to signed integer bounds must not overflow.
let edge = 0
for m in range(9223372036854775800, 9223372036854775807, 1):
    edge += m % 7
for n in range(-9223372036854775803, -9223372036854775808, -1):
    edge += n % 7
print(edge)
