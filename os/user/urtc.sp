# urtc: the real-time clock for user programs (the kernel reads the CMOS; see system call 1008)
import gdev

# [year, month, day, hour, minute, second]
export func now():
    return gdev.rtc()

func pad2(n):
    return ("0" .. to_string(n)) if n < 10 else to_string(n)

export func clock_text():
    let t = now()
    return pad2(t[3]) .. ":" .. pad2(t[4])

export func date_text():
    let t = now()
    return to_string(t[0]) .. "-" .. pad2(t[1]) .. "-" .. pad2(t[2]) .. " " .. pad2(t[3]) .. ":" .. pad2(t[4]) .. ":" .. pad2(t[5])
