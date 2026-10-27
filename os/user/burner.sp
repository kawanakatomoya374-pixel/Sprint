# a fixed amount of CPU work, to show that more processors finish the same jobs sooner
func spin(n):
    let s = 0
    for i in range(n):
        s += i % 7
    return s
spin(6000000)
