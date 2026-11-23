# jbench (user): the JIT benchmark of stdlib/jbench.sp in a ring-3 process (init=jbench)
import jbench as jb
import psys
for r in jb.run(() => psys.ms()):
    print("ubench " .. r[0] .. ": " .. to_string(r[1]) .. " ms")
