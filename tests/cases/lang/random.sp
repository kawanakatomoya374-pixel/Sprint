import random
random.seed(42)
let xs = []
for i in range(5):
    xs.append(random.int(1, 100))
print(xs)
print(random.float())
let a = [1,2,3,4,5,6,7,8]
random.shuffle(a)
print(a)
random.seed(-7)
print(random.int(-5, 5), random.int(0, 9223372036854775807))
