import math
let s = 0.0
for i in range(1, 3000000):
    let x = i * 0.001
    s += math.sin(x) * math.cos(x) + math.sqrt(x) + math.log(x) + math.exp(-x) + math.abs(math.floor(x) - x)
print(math.floor(s))
