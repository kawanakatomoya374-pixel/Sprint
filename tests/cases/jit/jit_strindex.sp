# s[i] on strings inside compiled loops: bytes, the end of the string, negative / float / out-of-range indices (errors raised by
# the interpreter after the compiled code left), multibyte text, and a string that changes type in the loop
func sum_bytes(s, n):
    let t = 0
    let i = 0
    while i < n:
        t = t + s[i]
        i += 1
    return t
print(sum_bytes("hello, world", 12))
print(sum_bytes("héllo wörld ✓", 17))

func count_char(s, ch):
    let n = len(s)
    let c = 0
    let i = 0
    while i < n:
        if s[i] == ch:
            c += 1
        i += 1
    return c
print(count_char("abracadabra" .. "abracadabra" .. "abracadabra", 97))
let big = "x".repeat(5000)
print(count_char(big, 120))

func past_end(s, n):
    let t = 0
    let i = 0
    while i < n:
        t = t + s[i]
        i += 1
    return t
try:
    print(past_end(big, 5001))
catch e:
    print(e.kind)

func negative(s, n):
    let t = 0
    let i = 3 - n
    while i < 3:
        t = t + s[i]
        i += 1
    return t
try:
    print(negative(big, 5000))
catch e:
    print(e.kind)

func float_index(s, n):
    let t = 0
    let i = 0.0
    while i < n:
        t = t + s[i]
        i += 1.0
    return t
try:
    print(float_index(big, 3000.0))
catch e:
    print(e.kind)

func mixed(s, n):
    let t = 0
    let i = 0
    let v = s
    while i < n:
        t = t + v[i % 4]
        if i == n - 2:
            v = [1, 2, 3, 4]
        i += 1
    return t
print(mixed("abcd", 4000))
