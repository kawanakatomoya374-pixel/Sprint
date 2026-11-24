# shm: shared memory segments. The pages of a segment are kept by the C side (shared.c), so processes on different CPUs can map the same one; a segment lives
# while some process has it mapped. Mapped (with the DEVICE bit, so address-space teardown never frees them) into every process that opens it.
import hw
import k
import vmm

const MAX_PAGES = 1024

# create a segment of `size` bytes and map it into p: [id, va, bytes] or [-errno, 0, 0]
export func create(p, size):
    let n = (size + 4095) // 4096
    if size <= 0 or n > MAX_PAGES:
        return [-22, 0, 0]
    if k.pages_free() < n + 16:
        return [-12, 0, 0]
    let id = k.shm_create(n)
    if id < 0:
        return [id, 0, 0]
    return [id, attach(p, id), n * 4096]

# turn n contiguous pages the caller already owns (a device's DMA memory) into a segment and map it into p: [id, va, bytes]
export func adopt(p, first, n):
    let id = k.shm_adopt(first, n)
    if id < 0:
        return [id, 0, 0]
    return [id, attach(p, id), n * 4096]

# map segment `id` into p; returns the address (negative errno on failure)
export func attach(p, id):
    let n = k.shm_n(id)
    if n == 0:
        return -22
    let va = p.mmap(n * 4096, vmm.W | vmm.U)      # the same address allocator (and region list) as every other mapping
    if va == 0:
        return -12
    for i in range(n):
        p.space.map(va + i * 4096, k.shm_page(id, i), vmm.W | vmm.U | vmm.DEVICE)
    k.shm_ref(id, 1)
    p.shm.append([id, va])
    return va

# map segment `id` into p at the given address (a Linux program's shmat); returns va, or a negative errno
export func attach_at(p, va, id):
    let n = k.shm_n(id)
    if n == 0:
        return -22
    for i in range(n):
        p.space.map(va + i * 4096, k.shm_page(id, i), vmm.W | vmm.U | vmm.DEVICE)
    k.shm_ref(id, 1)
    p.shm.append([id, va])
    return va

export func size_of(id):
    return k.shm_n(id) * 4096

export func detach(p, va):
    let i = 0
    while i < len(p.shm):
        let e = p.shm[i]
        if e[1] == va:
            p.shm.remove_at(i)
            p.space.unmap_free(va, k.shm_n(e[0]) * 4096)
            p.munmap(va, k.shm_n(e[0]) * 4096)
            k.shm_ref(e[0], -1)
            return 0
        i += 1
    return -22

export func detach_all(p):
    while len(p.shm) > 0:
        detach(p, p.shm[0][1])
