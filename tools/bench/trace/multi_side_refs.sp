# One loop site is exercised with a string Root plus array/table/nil/function
# Side traces. Returning and consuming the loop-carried reference verifies the
# native Snapshot writes the original tagged object back to the VM local.
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
    return [total, saved]

func consume(result):
    return result[0] + len(type(result[1]))

let sum = 0
sum += consume(ref_loop(1000000, "root"))
sum += consume(ref_loop(1000000, [1]))
sum += consume(ref_loop(1000000, {"key": 1}))
sum += consume(ref_loop(1000000, nil))
sum += consume(ref_loop(1000000, marker_fn))
sum += consume(ref_loop(1000000, "root"))
sum += consume(ref_loop(1000000, [2]))
sum += consume(ref_loop(1000000, {"key": 2}))
sum += consume(ref_loop(1000000, nil))
sum += consume(ref_loop(1000000, marker_fn))
sum += consume(ref_loop(1000000, "root"))
sum += consume(ref_loop(1000000, [3]))
sum += consume(ref_loop(1000000, {"key": 3}))
sum += consume(ref_loop(1000000, nil))
sum += consume(ref_loop(1000000, marker_fn))
print(sum)
