# ioapic: the I/O APIC, which routes device interrupts to the CPUs. Found through ACPI (the MADT lists the I/O APIC and the interrupt source overrides);
# the legacy 8259 PICs are masked by the CPU layer. Input n of the first I/O APIC is global system interrupt n (QEMU's machines have one 24-input chip).
import hw
import acpi

const DEFAULT_BASE = 0xFEC00000
export const VECTOR_BASE = 0x40       # input n interrupts with vector VECTOR_BASE + n (os/kernel/cpu.h: IRQ_BASE)
let base = 0
let overrides = {}                     # ISA irq -> [gsi, polarity, trigger] from the MADT

# the 2 MiB page of the kernel's identity map that holds the registers must be uncached
func make_uncached(addr):
    let pml4 = hw.kernel_cr3()
    let pdpt = hw.peek64(pml4) & 0x000FFFFFFFFFF000
    let pd = hw.peek64(pdpt + ((addr >> 30) & 511) * 8) & 0x000FFFFFFFFFF000
    let e = pd + ((addr >> 21) & 511) * 8
    hw.poke64(e, hw.peek64(e) | 0x18)
    hw.invlpg(addr)

export func init():
    let info = acpi.ioapic_info()
    base = info[0] if info[0] != 0 else DEFAULT_BASE
    overrides = info[1]
    make_uncached(base)
    hw.set_ioapic(base)
    let n = ((hw.ioapic_rd(1) >> 16) & 255) + 1       # number of redirection entries
    for i in range(n):
        hw.ioapic_wr(0x10 + 2 * i, 0x10000 | (VECTOR_BASE + i))    # masked
        hw.ioapic_wr(0x11 + 2 * i, 0)
    return n

# the global system interrupt an ISA irq arrives on
export func gsi_of(irq):
    return overrides[irq][0] if irq in overrides else irq

# route global interrupt `gsi` to vector VECTOR_BASE + gsi on the CPU with APIC id `apic`; ISA irqs are edge / active high unless the MADT says otherwise,
# PCI interrupts are level / active low. The input is left masked: the caller unmasks it.
export func route(gsi, apic, isa_irq):
    let low = true
    let level = true
    if isa_irq >= 0:
        low = false
        level = false
        if isa_irq in overrides:
            let o = overrides[isa_irq]
            if o[1] == 3:
                low = true
            if o[2] == 3:
                level = true
    let lo = 0x10000 | (VECTOR_BASE + gsi)
    if low:
        lo = lo | 0x2000
    if level:
        lo = lo | 0x8000
    hw.ioapic_wr(0x11 + 2 * gsi, apic << 24)
    hw.ioapic_wr(0x10 + 2 * gsi, lo)
