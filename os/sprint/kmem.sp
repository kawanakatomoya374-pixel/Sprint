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
