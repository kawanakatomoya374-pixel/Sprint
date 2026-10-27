func kind(x):
    return match x:
        case 0 => "zero"
        case n if type(n) == "int" and n < 0 => "neg"
        case [a, b] => "pair " .. to_string(a + b)
        case {name: s} => "named " .. s
        case _ => "other"
print(kind(0), kind(-3), kind([1, 2]), kind({name: "z"}), kind("q"))
let v = match 5:
    case 5 => 50
    case _ => 0
print(v + 1)
let label = match v > 10:
    case true => "big"
    case false => "small"
print(label)
# statement match with => arms
let seen = []
for i in range(3):
    match i:
        case 0 => seen.append("a")
        case 1:
            seen.append("b")
            seen.append("bb")
        case _ => seen.append("c")
print(seen)
# a match expression inside an arm of another one (via a function)
func two(x):
    return match x:
        case 2 => "two"
        case _ => "?"
let w = match 1:
    case 1 => two(2)
    case _ => "no"
print(w)
try:
    let z = match 9:
        case 1 => 1
    print(z)
catch e:
    print(e.kind)
