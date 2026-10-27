# lapic: the local APIC timer. Written in Sprint with MMIO through hw.peek32/poke32 and MSR access.
import hw

const BASE = 0xFEE00000
const REG_ID = 0x20
const REG_EOI = 0xB0
const REG_SVR = 0xF0
const REG_LVT_TIMER = 0x320
const REG_TIMER_INIT = 0x380
const REG_TIMER_CUR = 0x390
const REG_TIMER_DIV = 0x3E0
export const TIMER_VECTOR = 0x20
const MSR_APIC_BASE = 0x1B

let ticks_per_ms = 0

func rd(r):
    return hw.peek32(BASE + r)
func wr(r, v):
    hw.poke32(BASE + r, v)

# map the APIC page uncached: the kernel identity map uses 2 MiB pages, so patch the one covering BASE
func make_uncached():
    let pml4 = hw.kernel_cr3()
    let pdpt = hw.peek64(pml4) & 0x000FFFFFFFFFF000
    let pd = hw.peek64(pdpt + ((BASE >> 30) & 511) * 8) & 0x000FFFFFFFFFF000
    let e = pd + ((BASE >> 21) & 511) * 8
    hw.poke64(e, hw.peek64(e) | 0x18)   # PWT | PCD
    hw.invlpg(BASE)

export func id():
    return rd(REG_ID) >> 24

# enable the APIC and start a periodic timer with a period of `ms` milliseconds; returns the calibration
export func start(ms):
    make_uncached()
    hw.wrmsr(MSR_APIC_BASE, hw.rdmsr(MSR_APIC_BASE) | 0x800)
    wr(REG_SVR, 0x1FF)               # enable, spurious vector 0xFF
    wr(REG_TIMER_DIV, 3)             # divide by 16
    wr(REG_LVT_TIMER, 0x10000 | TIMER_VECTOR)   # masked one-shot while calibrating
    wr(REG_TIMER_INIT, 0xFFFFFFFF)
    let t0 = hw.ticks_us()
    while hw.ticks_us() - t0 < 10000:
        hw.pause()
    let used = 0xFFFFFFFF - rd(REG_TIMER_CUR)
    wr(REG_TIMER_INIT, 0)
    ticks_per_ms = used // 10
    if ticks_per_ms < 1:
        ticks_per_ms = 1
    hw.set_lapic(true)
    wr(REG_LVT_TIMER, 0x20000 | TIMER_VECTOR)   # periodic
    wr(REG_TIMER_INIT, ticks_per_ms * ms)
    return ticks_per_ms

export func eoi():
    wr(REG_EOI, 0)
