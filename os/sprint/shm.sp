# shm: shared memory segments. A segment is a list of physical pages mapped (with the DEVICE bit, so address-space
# teardown never frees them) into every process that opens it; it lives as long as some process has it mapped.
import hw
import kmem
import vmm

const MAX_PAGES = 1024
let segs = {}
let next_id = 1

# create a segment of `size` bytes and map it into p: [id, va, bytes] or [-errno, 0, 0]
export func create(p, size):
    let n = (size + 4095) // 4096
    if size <= 0 or n > MAX_PAGES:
        return [-22, 0, 0]
    if kmem.free_count() < n + 16:
        return [-12, 0, 0]
    let pages = []
    for i in range(n):
        pages.append(kmem.alloc())
    let id = next_id
    next_id += 1
    segs[id] = {pages: pages, refs: 0}
    return [id, attach(p, id), n * 4096]

# map segment `id` into p; returns the address (negative errno on failure)
export func attach(p, id):
    if not (id in segs):
        return -22
    let s = segs[id]
    let n = len(s.pages)
    let va = p.mmap_next
    p.mmap_next += n * 4096 + 4096
    for i in range(n):
        p.space.map(va + i * 4096, s.pages[i], vmm.W | vmm.U | vmm.DEVICE)
    s.refs += 1
    p.shm.append([id, va])
    return va

export func size_of(id):
    return len(segs[id].pages) * 4096 if id in segs else 0

export func detach(p, va):
    let k = 0
    while k < len(p.shm):
        let e = p.shm[k]
        if e[1] == va:
            p.shm.remove_at(k)
            let s = segs[e[0]]
            p.space.unmap_free(va, len(s.pages) * 4096)
            s.refs -= 1
            if s.refs == 0:
                for pg in s.pages:
                    kmem.release(pg)
                segs[e[0]] = nil
            return 0
        k += 1
    return -22

export func detach_all(p):
    while len(p.shm) > 0:
        detach(p, p.shm[0][1])
