let seed = 113
func rnd():
    seed = (seed * 16807) % 2147483647
    return seed / 2147483647.0
func pi_est(n):
    let inside = 0
    for i in range(n):
        let x = rnd()
        let y = rnd()
        if x * x + y * y <= 1.0:
            inside += 1
    return inside
print(pi_est(6000000))
