func f():
    throw error("MyErr", "boom")
try:
    f()
catch e:
    print(e.kind, e.message)
try:
    print(1 // 0)
catch e:
    print(e.kind)
try:
    print(nil + 1)
catch e:
    print(e.kind)
assert 1 == 2, "nope"
