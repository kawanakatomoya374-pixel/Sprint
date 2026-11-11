func bfs(w, h, walls):
    let n = w * h
    let dist = []
    dist.reserve(n)
    for i in range(n):
        dist.append(-1)
    let q = []
    q.reserve(n)
    q.append(0)
    dist[0] = 0
    let head = 0
    while head < len(q):
        let cur = q[head]
        head += 1
        let x = cur % w
        let y = cur // w
        let d = dist[cur] + 1
        if x > 0 and dist[cur - 1] < 0 and walls[cur - 1] == 0:
            dist[cur - 1] = d
            q.append(cur - 1)
        if x < w - 1 and dist[cur + 1] < 0 and walls[cur + 1] == 0:
            dist[cur + 1] = d
            q.append(cur + 1)
        if y > 0 and dist[cur - w] < 0 and walls[cur - w] == 0:
            dist[cur - w] = d
            q.append(cur - w)
        if y < h - 1 and dist[cur + w] < 0 and walls[cur + w] == 0:
            dist[cur + w] = d
            q.append(cur + w)
    return dist
let w = 2400
let h = 2000
let walls = []
walls.reserve(w * h)
let seed = 11
for i in range(w * h):
    seed = (seed * 16807) % 2147483647
    walls.append(1 if seed % 100 < 22 else 0)
walls[0] = 0
let dist = bfs(w, h, walls)
let reach = 0
let far = 0
for d in dist:
    if d >= 0:
        reach += 1
        if d > far:
            far = d
print(reach, far)
