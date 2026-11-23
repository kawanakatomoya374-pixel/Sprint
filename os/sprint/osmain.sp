# Sprint OS kernel entry (ring 0). Every CPU runs this program in its own Sprint VM. The boot processor sets the machine up (memory, interrupts), starts the
# other processors and spawns the first process; an application processor only brings its own scheduler up. Then each CPU runs its scheduler loop (C: smp.c)
# calling sched.pick / sched.trap of its own VM - there is no lock between them.
import hw
import k
import kmem
import lapic
import acpi
import sched
import ksys
import ioapic
import jbench

func log(s):
    ksys.log(s)

let cpu = hw.cpu_id()
let img = hw.initrd()
if cpu != 0:
    sched.init(img, cpu)
    hw.set_hooks(sched.pick, sched.trap)
    k.ready_set(cpu)
else:
    log("physical pages: " .. to_string(kmem.init()))
    log("userland image: " .. to_string(img[1]) .. " bytes")
    let per_ms = lapic.start(10)
    log("local APIC timer: " .. to_string(per_ms) .. " ticks/ms")
    log("I/O APIC: " .. to_string(ioapic.init()) .. " inputs")
    hw.set_timer(per_ms * 10)
    sched.init(img, 0)
    hw.set_hooks(sched.pick, sched.trap)
    k.ready_set(0)

    # bring up the other processors (INIT + SIPI); each creates its own kernel VM and scheduler, then reports in
    let ids = acpi.cpus()
    let me = lapic.id()
    let started = [0]
    let idx = 1
    for apic in ids:
        if apic != me and idx < 8:
            if hw.ap_start(apic, idx):
                started.append(idx)
            else:
                log("cpu with APIC id " .. to_string(apic) .. " did not start")
            idx += 1
    hw.ap_go()
    let t0 = hw.ticks_us()
    for c in started:
        while not k.ready(c) and hw.ticks_us() - t0 < 10000000:
            hw.pause()
    let online = 0
    for c in started:
        if k.ready(c):
            online += 1
    log("processors online: " .. to_string(online) .. " of " .. to_string(len(ids)))

    # kernel command line: init=NAME picks the first user program (default: boot)
    let first = "boot"
    for word in hw.cmdline().split(" "):
        if word.starts_with("init="):
            first = word.slice(5, len(word))
    log("first process: " .. first)
    sched.spawn(first, 0)
    sched.boot_done()

    # `kbench` on the kernel command line: how fast does Sprint code run in the kernel itself? (the JIT benchmark of stdlib/jbench.sp)
    for word in hw.cmdline().split(" "):
        if word == "kbench":
            for r in jbench.run(() => hw.ticks_us() // 1000):
                log("kbench " .. r[0] .. ": " .. to_string(r[1]) .. " ms")
