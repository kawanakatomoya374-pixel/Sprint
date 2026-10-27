# psys: process and time calls for programs running on Sprint OS. Output is flushed before anything that can
# block or switch, so what concurrent processes print appears in the order it happened.
import io
import sysraw as raw

export func pid():
    return raw.pid()
export func ms():
    return raw.ms()
export func spawn(name):
    io.flush()
    return raw.spawn(name)
export func wait(p):
    io.flush()
    return raw.wait(p)
export func sleep_ms(n):
    io.flush()
    raw.sleep_ms(n)
export func relax():
    io.flush()
    raw.yield()
export func exit(code):
    io.flush()
    raw.exit(code)
