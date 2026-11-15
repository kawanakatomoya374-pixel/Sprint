let seed = 23
let rows = []
for i in range(40000):
    let cells = []
    for j in range(8):
        seed = (seed * 16807) % 2147483647
        cells.append(to_string(seed % 100000))
    rows.append(cells.join(","))
let text = rows.join("\n")
let total = 0
for r in range(3):
    let lines = text.split("\n")
    for line in lines:
        let f = line.split(",")
        total += to_int(f[0]) + to_int(f[3]) - to_int(f[7])
print(total, len(text))
