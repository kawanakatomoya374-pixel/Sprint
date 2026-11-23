# kmem: the kernel's physical page allocator for user memory. The pages are kept by the C side (shared.c: one bitmap behind a lock) because every CPU's kernel
# allocates from it. Pages are 4 KiB; alloc() returns the address of a zeroed page (physical == virtual in the kernel's identity map).
import k

export func init():
    return k.pages_total()

export func alloc():
    let a = k.page_alloc()
    if a == 0:
        throw error("MemoryError", "kernel: out of physical pages")
    return a

export func release(a):
    k.page_free(a)

export func free_count():
    return k.pages_free()

export func total_count():
    return k.pages_total()

# n physically contiguous zeroed pages (a device's DMA ring), or 0 when no such run is free
export func alloc_contig(n):
    return k.page_alloc_contig(n)
