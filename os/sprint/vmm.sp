# vmm: address spaces. A space is a 4-level x86-64 page table written and walked here, in Sprint, with
# hw.peek64/poke64 (the kernel sees all RAM through its identity map). PML4 entry 0 is shared with the
# kernel (supervisor-only), so a trap can run kernel code under any space; user memory starts at 512 GiB.
import hw
import kmem

export const PAGE = 4096
export const P = 1
export const W = 2
export const U = 4
export const NX = 1 << 63
export const DEVICE = 1 << 9   # software bit: a device page (framebuffer); never returned to the allocator
export const USER_BASE = 0x8000000000
const ADDR_MASK = 0x000FFFFFFFFFF000

func idx(v, level):
    return (v >> (12 + 9 * level)) & 511

export class Space:
    let pml4 = 0
    let tables = []
    let pages = []
    func init(self):
        self.pml4 = kmem.alloc()
        self.tables = [self.pml4]
        self.pages = []
        hw.poke64(self.pml4, hw.peek64(hw.kernel_cr3()))   # entry 0: the kernel's identity map
    # the page-table entry address for v, creating tables when `create`
    func entry(self, v, create):
        let t = self.pml4
        for level in [3, 2, 1]:
            let e = t + idx(v, level) * 8
            let x = hw.peek64(e)
            if x & P == 0:
                if not create:
                    return 0
                let n = kmem.alloc()
                self.tables.append(n)
                hw.poke64(e, n | P | W | U)
                x = n | P | W | U
            t = x & ADDR_MASK
        return t + idx(v, 0) * 8
    func map(self, v, phys, flags):
        hw.poke64(self.entry(v, true), phys | flags | P)
        hw.invlpg(v)
    func unmap(self, v):
        let e = self.entry(v, false)
        if e != 0:
            hw.poke64(e, 0)
            hw.invlpg(v)
    # physical address for v (with the offset), or nil
    func translate(self, v):
        let e = self.entry(v & ~(PAGE - 1), false)
        if e == 0:
            return nil
        let x = hw.peek64(e)
        if x & P == 0:
            return nil
        return (x & ADDR_MASK) + (v & (PAGE - 1))
    func flags_of(self, v):
        let e = self.entry(v & ~(PAGE - 1), false)
        return 0 if e == 0 else hw.peek64(e)
    # back [v, v + len) with fresh zeroed pages (already-mapped pages are kept)
    func map_range(self, v, len, flags):
        let a = v & ~(PAGE - 1)
        let end = v + len
        while a < end:
            if self.translate(a) == nil:
                let p = kmem.alloc()
                self.pages.append(p)
                self.map(a, p, flags)
            a += PAGE
    func is_mapped(self, v):
        return self.translate(v) != nil
    # copy bytes in and out of user memory page by page (the kernel cannot trust user pointers)
    func read(self, v, n):
        let out = []
        while n > 0:
            let p = self.translate(v)
            if p == nil:
                return nil
            let chunk = PAGE - (v & (PAGE - 1))
            if chunk > n:
                chunk = n
            out.append(hw.str_at(p, chunk))
            v += chunk
            n -= chunk
        return out.join("")
    func write(self, v, s):
        let n = len(s)
        let off = 0
        while off < n:
            let p = self.translate(v + off)
            if p == nil:
                return false
            let chunk = PAGE - ((v + off) & (PAGE - 1))
            if chunk > n - off:
                chunk = n - off
            hw.poke_str(p, s.slice(off, off + chunk))
            off += chunk
        return true
    # write raw bytes (an array of ints 0..255)
    func write_bytes(self, v, bytes):
        for i in range(len(bytes)):
            let p = self.translate(v + i)
            if p == nil:
                return false
            hw.poke8(p, bytes[i])
        return true
    func read64(self, v):
        let p = self.translate(v)
        return nil if p == nil else hw.peek64(p)
    func write64(self, v, x):
        let p = self.translate(v)
        if p == nil:
            return false
        hw.poke64(p, x)
        return true
    # move the frame mapped at src to dst (no copy); false when src is not mapped
    func move_page(self, src, dst):
        let e = self.entry(src, false)
        if e == 0:
            return false
        let x = hw.peek64(e)
        if x & P == 0:
            return false
        hw.poke64(self.entry(dst, true), x)
        hw.poke64(e, 0)
        hw.invlpg(src)
        hw.invlpg(dst)
        return true
    # unmap [v, v + len) and give the frames back
    func unmap_free(self, v, len):
        let a = v & ~(PAGE - 1)
        let end = v + len
        while a < end:
            let e = self.entry(a, false)
            if e != 0:
                let x = hw.peek64(e)
                if x & P != 0:
                    if x & DEVICE == 0:
                        kmem.release(x & ADDR_MASK)
                    hw.poke64(e, 0)
                    hw.invlpg(a)
            a += PAGE
    # give every frame and table back (entry 0 of the PML4 is the shared kernel map and is left alone)
    func destroy(self):
        free_tree(self.pml4, 3, 1)
        kmem.release(self.pml4)
        self.tables = []
        self.pages = []

func free_tree(t, level, first):
    for i in range(first, 512):
        let x = hw.peek64(t + i * 8)
        if x & P == 0:
            continue
        let a = x & ADDR_MASK
        if level > 0:
            free_tree(a, level - 1, 0)
        if level > 0 or x & DEVICE == 0:
            kmem.release(a)
