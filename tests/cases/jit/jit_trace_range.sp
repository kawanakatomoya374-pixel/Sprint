# for-in-range loops compiled by the TraceJIT: ascending / descending / strided ranges, an empty range, a body that branches, a
# nested loop, break, the loop variable used after the loop, and a range that ends at the top of the int range
func asc(n):
    let s = 0
    for i in range(n):
        s = s + i % 8 + i // 4
    return s
print(asc(5000), asc(0), asc(1))

func desc(n):
    let s = 0
    for i in range(n, 0, 0 - 1):
        s = s + i * 3 - i // 2
    return s
print(desc(5000))

func strided(n, k):
    let s = 0
    for i in range(0, n, k):
        s = s + i
    return s
print(strided(10000, 7), strided(10000, 1), strided(10000, 9999))

func branchy(n):
    let even = 0
    let odd = 0
    for i in range(n):
        if i % 2 == 0:
            even = even + i
        else:
            odd = odd + 1
    return [even, odd]
print(branchy(4000))

func nested(n):
    let s = 0
    for i in range(n):
        for j in range(8):
            s = s + i * j
    return s
print(nested(3000))

func early(n):
    let s = 0
    let last = 0 - 1
    for i in range(n):
        if i == 2500:
            break
        s = s + i
        last = i
    return [s, last]
print(early(5000))

func top_of_range():
    let s = 0
    for i in range(9223372036854775800, 9223372036854775807):
        s = s + 1
    return s
print(top_of_range())

func changing_step(n):
    let total = 0
    let k = 1
    while k < 4:
        for i in range(0, n, k):
            total = total + i % 5
        k += 1
    return total
print(changing_step(3000))

func overflow_inside(n):
    let s = 0
    for i in range(n):
        s = s + 4611686018427387904
    return s
try:
    print(overflow_inside(10))
catch e:
    print(e.kind)
