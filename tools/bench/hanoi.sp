func hanoi(n, src, to, mid, counts):
    if n == 0:
        return
    hanoi(n - 1, src, mid, to, counts)
    counts[src] += 1
    counts[to] += 2
    hanoi(n - 1, mid, to, src, counts)
let counts = [0, 0, 0]
for r in range(6):
    hanoi(22, 0, 2, 1, counts)
print(counts[0], counts[1], counts[2])
