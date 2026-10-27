func describe(v):
    match v:
        case 0:
            return "zero"
        case -1:
            return "minus one"
        case "hi":
            return "greeting"
        case [x, y] if x == y:
            return "pair of " .. x
        case [x, [y, _]]:
            return "nested " .. x .. y
        case {kind: "circle", r: r}:
            return "circle " .. r
        case {"a b": q}:
            return "q " .. q
        case nil:
            return "nil"
        case true:
            return "yes"
        case n if type(n) == "int":
            return "int " .. n
        case _:
            return "other"
print(describe(0), describe(-1), describe("hi"))
print(describe([2, 2]), describe([1, [2, 3]]))
print(describe({kind: "circle", r: 5, extra: 1}), describe({"a b": 7}))
print(describe(nil), describe(true), describe(42), describe(3.5))
print(describe([1, 2]))
let fs = []
match [1, 2]:
    case [a, b]:
        fs.append(func(): a + b)
print(fs[0]())
match 5:
    case 1:
        print("no")
