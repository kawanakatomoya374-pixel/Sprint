# acpi: just enough of ACPI to find the processors. RSDP -> RSDT/XSDT -> MADT -> local-APIC entries.
import hw

func sig(a, n):
    return hw.str_at(a, n)

# [I/O APIC address (0 if none), {ISA irq: [global system interrupt, polarity, trigger]}] from the MADT (polarity / trigger: 0 = bus default, 1 = high / edge, 3 = low / level)
export func ioapic_info():
    let rsdp = hw.rsdp()
    let addr = 0
    let ov = {}
    if rsdp == 0 or sig(rsdp, 8) != "RSD PTR ":
        return [0, ov]
    let tables = []
    let rev = hw.peek8(rsdp + 15)
    if rev >= 2 and hw.peek64(rsdp + 24) != 0:
        let x = hw.peek64(rsdp + 24)
        for i in range((hw.peek32(x + 4) - 36) // 8):
            tables.append(hw.peek64(x + 36 + i * 8))
    else:
        let r = hw.peek32(rsdp + 16)
        for i in range((hw.peek32(r + 4) - 36) // 4):
            tables.append(hw.peek32(r + 36 + i * 4))
    for t in tables:
        if sig(t, 4) == "APIC":
            let end = t + hw.peek32(t + 4)
            let e = t + 44
            while e + 2 <= end:
                let kind = hw.peek8(e)
                let len = hw.peek8(e + 1)
                if len < 2:
                    break
                if kind == 1 and addr == 0:
                    addr = hw.peek32(e + 4)
                elif kind == 2:
                    let fl = hw.peek16(e + 8)
                    ov[hw.peek8(e + 3)] = [hw.peek32(e + 4), fl & 3, (fl >> 2) & 3]
                e += len
    return [addr, ov]

# the APIC ids of all enabled processors (the boot processor included), or [] when there are no tables
export func cpus():
    let rsdp = hw.rsdp()
    if rsdp == 0 or sig(rsdp, 8) != "RSD PTR ":
        return []
    let tables = []
    let rev = hw.peek8(rsdp + 15)
    if rev >= 2 and hw.peek64(rsdp + 24) != 0:
        let x = hw.peek64(rsdp + 24)
        let n = (hw.peek32(x + 4) - 36) // 8
        for i in range(n):
            tables.append(hw.peek64(x + 36 + i * 8))
    else:
        let r = hw.peek32(rsdp + 16)
        let n = (hw.peek32(r + 4) - 36) // 4
        for i in range(n):
            tables.append(hw.peek32(r + 36 + i * 4))
    for t in tables:
        if sig(t, 4) == "APIC":
            let ids = []
            let end = t + hw.peek32(t + 4)
            let e = t + 44
            while e + 2 <= end:
                let kind = hw.peek8(e)
                let len = hw.peek8(e + 1)
                if len < 2:
                    break
                if kind == 0 and (hw.peek32(e + 4) & 3) != 0:   # enabled or online-capable
                    ids.append(hw.peek8(e + 3))
                e += len
            return ids
    return []
