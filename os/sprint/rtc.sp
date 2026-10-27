# rtc: the battery-backed real-time clock (CMOS ports 0x70/0x71).
import hw

func reg(r):
    hw.outb(0x70, r)
    return hw.inb(0x71)

func busy():
    return reg(0x0A) & 0x80 != 0

func bcd(v, binary):
    return v if binary else (v & 15) + (v >> 4) * 10

# [year, month, day, hour, minute, second]
export func now():
    for i in range(1000):
        if not busy():
            break
    let sec = reg(0)
    let min = reg(2)
    let hour = reg(4)
    let day = reg(7)
    let mon = reg(8)
    let yr = reg(9)
    let b = reg(0x0B)
    let binary = b & 4 != 0
    let pm = hour & 0x80 != 0
    hour = bcd(hour & 0x7F, binary)
    if b & 2 == 0 and pm:
        hour = (hour + 12) % 24
    return [2000 + bcd(yr, binary), bcd(mon, binary), bcd(day, binary), hour, bcd(min, binary), bcd(sec, binary)]

func pad2(n):
    return ("0" .. to_string(n)) if n < 10 else to_string(n)

export func clock_text():
    let t = now()
    return pad2(t[3]) .. ":" .. pad2(t[4])

export func date_text():
    let t = now()
    return to_string(t[0]) .. "-" .. pad2(t[1]) .. "-" .. pad2(t[2]) .. " " .. pad2(t[3]) .. ":" .. pad2(t[4]) .. ":" .. pad2(t[5])
