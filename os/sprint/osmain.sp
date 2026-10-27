# Sprint OS kernel entry (ring 0): memory, interrupts, the other processors, then hand over to the scheduler.
import hw
import kmem
import lapic
import acpi
import sched
import ksys

func log(s):
    ksys.log(s)

log("physical pages: " .. to_string(kmem.init()))
let img = hw.initrd()
log("userland image: " .. to_string(img[1]) .. " bytes")
let per_ms = lapic.start(10)
log("local APIC timer: " .. to_string(per_ms) .. " ticks/ms")
hw.set_timer(per_ms * 10)
sched.init(img)
# kernel command line: init=NAME picks the first user program (default: boot)
let first = "boot"
for word in hw.cmdline().split(" "):
    if word.starts_with("init="):
        first = word.slice(5, len(word))
log("first process: " .. first)
sched.spawn(first, 0)
hw.set_hooks(sched.pick, sched.trap)

# bring up the other processors (INIT + SIPI); each one then runs the same scheduler loop
let ids = acpi.cpus()
let me = lapic.id()
let started = 1
let idx = 1
for apic in ids:
    if apic != me and idx < 16:
        if hw.ap_start(apic, idx):
            started += 1
        else:
            log("cpu with APIC id " .. to_string(apic) .. " did not start")
        idx += 1
log("processors online: " .. to_string(started) .. " of " .. to_string(len(ids)))
