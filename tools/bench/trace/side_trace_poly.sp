func sum_to(n):
    let i = n - n
    let total = n - n
    while i < n:
        total += i
        i += 1
    return total

let warm1 = sum_to(5000)
let warm2 = sum_to(5000)
let reps = 600
let result = 0.0
while reps > 0:
    result += sum_to(5000.0)
    reps -= 1
print(result)
