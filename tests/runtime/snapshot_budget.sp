func consume(n):
    let i = 0
    let sum = 0
    while i < n:
        sum += i
        i += 1
    return sum

print(consume(10000000))
