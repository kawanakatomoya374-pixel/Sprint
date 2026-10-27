# Register temporaries: array elements, fields and + - * / results kept in machine registers must behave exactly like the
# interpreter, including guard exits taken while values are live (type changes, zero divisors, overflow, bad indexes).
import math
class V:
    let x = 1
    let y = 2
    let f = 0.5
    let g = 1.5
    let row = nil
    func init(self, x, y):
        self.x = x
        self.y = y

func nested(n):
    let M = [[1, 2, 3], [4, 5, 6], [7, 8, 9]]
    let s = 0
    for i in range(n):
        s += M[i % 3][(i + 1) % 3] * M[(i + 2) % 3][i % 3] - M[0][1] * M[2][2]
    return s
print(nested(3000))

func fields(n):
    let v = V(3, 4)
    let s = 0
    for i in range(n):
        s += v.x * v.y + v.x - v.y * i
        v.x = (v.x + v.y) % 101
        v.y = (v.x * 3 + i) % 103
    return [s, v.x, v.y]
print(fields(2000))

func floats(n):
    let F = [0.5, 1.5, 2.5, 0.25]
    let v = V(1, 2)
    let s = 0.0
    for i in range(n):
        s += F[i % 4] * v.f + F[(i + 1) % 4] / (v.g + 1.0) - v.f * v.g
        F[i % 4] = (F[i % 4] + s * 0.001) / 1.0001
    return [s, F]
print(floats(1000))

func deep(n):
    let A = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
    let s = 0
    for i in range(n):
        s += (A[0] + (A[1] + (A[2] + (A[3] + (A[4] + (A[5] + (A[6] + (A[7] + (A[8] + A[9]) * 2) * 2) * 2) * 2) * 2) * 2) * 2) * 2) - i
    return s
print(deep(500))

func fdeep(n):
    let F = [1.5, 2.5, 3.5, 4.5, 5.5, 6.5, 7.5, 8.5, 9.5]
    let s = 0.0
    for i in range(n):
        s += (F[0] * (F[1] + (F[2] * (F[3] + (F[4] * (F[5] + (F[6] * (F[7] + F[8])))))))) * 0.0000001
    return s
print(fdeep(500))

func compares(n):
    let A = [5, 3, 8, 1, 9, 2]
    let F = [0.5, 0.25, nil, 3.0]
    let k = 0
    for i in range(n):
        if A[i % 6] < A[(i + 1) % 6] * 2:
            k += 1
        if A[i % 6] >= A[(i + 2) % 6] + 1:
            k += 10
        if A[i % 6] == A[(i + 3) % 6] - 1:
            k += 100
        if A[i % 6] != A[(i + 4) % 6]:
            k += 1000
        if F[i % 2] <= F[(i + 1) % 2] * 2.0:
            k += 10000
        if F[3] > F[i % 2] - 0.5:
            k += 100000
    return k
print(compares(600))

func divzero(n):
    let F = [1.0, 2.0, 0.0, 4.0]
    let s = 0.0
    for i in range(n):
        s += F[0] / (F[i % 4] + F[1] * 0.0)
    return s
try:
    print(divzero(10))
catch e:
    print("caught", e.kind)

func flip(n):
    let A = [1, 2, 3, 4]
    let v = V(5, 6)
    let s = 0
    for i in range(n):
        if i == 120:
            A[2] = 2.5
        if i == 240:
            v.x = 0.5
        s += A[i % 4] * v.x + v.y
    return s
print(flip(400))

func overflow(n):
    let A = [3, 5, 7]
    let x = 1
    for i in range(n):
        x = x * A[i % 3] + A[(i + 1) % 3]
    return x
try:
    print(overflow(100))
catch e:
    print("caught", e.kind)

func badindex(n):
    let A = [1, 2, 3, 4]
    let s = 0
    for i in range(n):
        s += A[i // 10] * 2 + A[0]
    return s
try:
    print(badindex(100))
catch e:
    print("caught", e.kind)

func stores(n):
    let A = [0, 0, 0, 0]
    let F = [0.0, 0.0]
    let M = [[0, 0], [0, 0]]
    let v = V(1, 1)
    for i in range(n):
        A[i % 4] = A[(i + 1) % 4] + v.x * 2 - i
        F[i % 2] = F[(i + 1) % 2] * 0.5 + v.f + i
        M[i % 2][(i + 1) % 2] = A[i % 4] - M[(i + 1) % 2][i % 2]
        v.x = A[i % 4] % 10
        v.f = F[i % 2] / 3.0
    return [A, F, M, v.x, v.f]
print(stores(1000))

func mixed(n):
    let A = [1, 2, 3]
    let F = [0.5, 1.5, 2.5]
    let s = 0.0
    for i in range(n):
        s += A[i % 3] * F[i % 3] + F[(i + 1) % 3] - A[(i + 2) % 3] / 2
    return s
print(mixed(900))

func rowfields(n):
    let v = V(1, 2)
    v.row = [10, 20, 30]
    let s = 0
    for i in range(n):
        s += v.row[i % 3] * v.x + v.row[(i + 1) % 3]
    return s
print(rowfields(600))

func roots(n):
    let A = [4, 9, 16, 25]
    let F = [2.25, 6.25, 0.0, 100.0]
    let s = 0.0
    for i in range(n):
        s += math.sqrt(A[i % 4]) + math.sqrt(F[i % 4] * 2.0) * math.sqrt(i)
    return s
print(roots(400))

func negroot(n):
    let F = [4.0, 1.0, -2.0, 9.0]
    let s = 0.0
    for i in range(n):
        s += math.sqrt(F[i % 4] * 1.0)
    return s
try:
    print(negroot(20))
catch e:
    print("caught", e.kind)

func chain(n):
    let x = 1.0
    let y = 2.0
    let z = 3
    let k = 0
    for i in range(n):
        x = x * 1.0001 + y * 0.5
        y = y + x * 0.0001 - z
        z = (z * 3 + k) % 17
        k = k + z - i % 3
        if x > 1000.0:
            x = 1.0
        if y < -1000.0:
            y = 2.0
    return [x, y, z, k]
print(chain(5000))
