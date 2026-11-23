# kmem: the kernel's physical page allocator (policy in Sprint; the C side only hands over the ranges).
# Pages are 4 KiB; alloc() returns the address of a zeroed page (physical == virtual in the kernel's
# identity map).
import hw

const PAGE = 4096
let free_pages = []
let total = 0

export func init():
    for r in hw.user_mem():
        let a = (r[0] + PAGE - 1) // PAGE * PAGE
        let end = (r[0] + r[1]) // PAGE * PAGE
        while a < end:
            free_pages.append(a)
            a += PAGE
    total = len(free_pages)
    return total

export func alloc():
    if len(free_pages) == 0:
        throw error("MemoryError", "kernel: out of physical pages")
    let a = free_pages.pop()
    hw.memset(a, 0, PAGE)
    return a

export func release(a):
    free_pages.append(a)

export func free_count():
    return len(free_pages)

export func total_count():
    return total

# n physically contiguous zeroed pages (a device's DMA ring), or 0 when no such run is free
export func alloc_contig(n):
    if n <= 0 or n > len(free_pages):
        return 0
    let sorted = free_pages.copy()
    sorted.sort((a, b) => a < b)
    let run = 1
    let start = 0
    for i in range(1, len(sorted)):
        if sorted[i] == sorted[i - 1] + PAGE:
            run += 1
        else:
            run = 1
            start = i
        if run >= n:
            let first = sorted[start]
            let want = {}
            for k in range(n):
                want[to_string(first + k * PAGE)] = true
            let keep = []
            for a in free_pages:
                if not (to_string(a) in want):
                    keep.append(a)
            free_pages = keep
            for k in range(n):
                hw.memset(first + k * PAGE, 0, PAGE)
            return first
    if n == 1 and len(sorted) > 0:
        return alloc()
    return 0
