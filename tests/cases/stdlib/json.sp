import json
import math
let v = json.parse("{\"a\": [1, 2.5, -3, 1e2, true, null], \"b\": {\"c\": \"x\\u00e9\\n\\ud83d\\ude00\"}, \"a\": 9}")
print(v.a, v.b.c.char_count(), len(v))
print(json.stringify(v))
print(json.stringify([1, "a\"b\\", nil, 2.0, {"k": []}]))
print(json.stringify({"x": [1, {"y": 2}], "z": {}}, 2))
print(json.parse("12345678901234567890"), type(json.parse("12")), type(json.parse("12.0")))
for bad in ["", "[1,]", "{\"a\":1,}", "01", "[1] x", "\"abc", "nul", "\"\\ud800\"", "[\"\t\"]", "1e999"]:
    try:
        json.parse(bad)
        print("accepted", bad)
    catch e:
        print(e.kind, e.data.line, e.data.column)
for bad in [{1: 2}, [math.nan], print, [math.inf]]:
    try:
        json.stringify(bad)
    catch e:
        print(e.kind)
let deep = []
let cur = deep
for i in range(600):
    let n = []
    cur.append(n)
    cur = n
try:
    json.stringify(deep)
catch e:
    print(e.kind)
try:
    json.parse(json.stringify([1]) .. "[" .. "[".repeat(600))
catch e:
    print(e.kind)
