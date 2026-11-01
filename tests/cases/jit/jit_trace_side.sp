# One loop site first specializes as integer, then records a float Side Trace.
func polymorphic_loop(n):
    let i = n - n
    let total = n - n
    while i < n:
        total += i
        i += 1
    let j = n - n
    while j < n:
        total += j
        j += 1
    return total

# The second root is reached after initialization which is independent of root one.
# Its guard can miss after a direct native link from the first root.
func linked_side(n, m):
    let i = 0
    let total = 0
    let j = m - m
    let second = m - m
    while i < n:
        total += i
        i += 1
    while j < m:
        second += j
        j += 1
    return total + second

print(polymorphic_loop(1000))
print(polymorphic_loop(1000.0))
print(polymorphic_loop(1000.0))
print(polymorphic_loop(10.5))
print(linked_side(1000, 1000))
print(linked_side(1000, 1000))
print(linked_side(1000, 1000.0))
print(linked_side(1000, 1000.0))

import gc

# One Root Trace has several reference-type variants. The saved local is a
# loop-carried reference so each runtime SpType receives its own Side Trace.
func marker_fn():
    return 7

func ref_loop(n, marker):
    let i = 0
    let total = 0
    let saved = marker
    while i < n:
        saved = marker
        total += i
        i += 1
    # Return the loop-carried reference too: this verifies that native
    # Snapshot materialization preserves the tagged pointer for VM/GC use.
    return [total, saved]

func show_after_gc(n, marker):
    let result = ref_loop(n, marker)
    gc.collect()
    print(result)

show_after_gc(1000, "root-string")
show_after_gc(1000, [1])
show_after_gc(1000, {"key": "value"})
show_after_gc(1000, [2])
show_after_gc(1000, "again-string")
show_after_gc(1000, nil)
show_after_gc(1000, marker_fn)
show_after_gc(1000, marker_fn)
# The fifth alternate signature is safely interpreted after the four-child cap.
show_after_gc(1000, true)
show_after_gc(1000, true)
