# netd: the network card driver server. A user process (not part of the kernel) for Intel E1000 / E1000E (82540EM, 82574L, ...): it maps the card's registers,
# keeps the receive and transmit descriptor rings in DMA memory, and works entirely from interrupts: it sleeps in ipc.recv_from() until the kernel posts
# "irq<TAB>n", reads the card's cause register, takes the received frames off the ring, acknowledges the interrupt and goes back to sleep. Nothing polls the card.
# The PCI interrupt pin is routed to an I/O APIC input by the chipset; which one is found by making the card raise a test interrupt (ICS) and seeing
# where it arrives (the BIOS's interrupt line, and inputs 16-19 as on Q35 machines, are all armed; the one the card's interrupt arrives on is kept).
#
# It answers "mac" and "stats" and, as a self test, sends an ARP request for the QEMU gateway (10.0.2.2) once the first interrupt has shown that
# interrupts work, and logs the reply it receives.
#
# The frame interface for a network stack process (one subscriber, one frame at a time, over a shared segment the stack creates):
#   stack -> netd   "sub<TAB>segment id"   netd maps the segment and answers "ok<TAB>MAC". Bytes 0..2047 of the segment carry a received frame, bytes 2048..4095 a frame to send.
#   netd -> stack   "rx<TAB>length"        a received frame is in the segment; netd sends the next one only after the stack answers
#   stack -> netd   "ack"                  the received frame has been taken (netd keeps up to 64 frames waiting meanwhile, drops the rest)
#   stack -> netd   "tx<TAB>length"        send the frame in the transmit half; netd copies it into the ring and answers "ok"
#   stack -> netd   "unsub"
import io
import ipc
import uio
import psys

func log(s):
    print("[netd] " .. s)
    io.flush()

# ---- PCI -------------------------------------------------------------------------------------------------------------------
func cfg_addr(bdf, off):
    return 0x80000000 | (bdf[0] << 16) | (bdf[1] << 11) | (bdf[2] << 8) | (off & 0xFC)

func cfg_r32(bdf, off):
    uio.outl(0xCF8, cfg_addr(bdf, off))
    return uio.inl(0xCFC)

func cfg_w32(bdf, off, v):
    uio.outl(0xCF8, cfg_addr(bdf, off))
    uio.outl(0xCFC, v)

const DEVICES = [0x1000, 0x1001, 0x1004, 0x1008, 0x100E, 0x100F, 0x1010, 0x1011, 0x1026, 0x1027, 0x1028, 0x10D3, 0x10F5, 0x153A, 0x1502]

func pci_find():
    for dev in range(32):
        for fn in range(8):
            let bdf = [0, dev, fn]
            let id = cfg_r32(bdf, 0)
            if id == 0xFFFFFFFF:
                if fn == 0:
                    break
                continue
            if (id & 0xFFFF) == 0x8086 and DEVICES.contains(id >> 16):
                return [bdf, id >> 16]
            if fn == 0 and ((cfg_r32(bdf, 0x0C) >> 16) & 0x80) == 0:
                break
    return nil

# ---- registers -------------------------------------------------------------------------------------------------------------
const CTRL = 0x0000
const STATUS = 0x0008
const ICR = 0x00C0
const ICS = 0x00C8
const IMS = 0x00D0
const IMC = 0x00D8
const RCTL = 0x0100
const TCTL = 0x0400
const TIPG = 0x0410
const RDBAL = 0x2800
const RDBAH = 0x2804
const RDLEN = 0x2808
const RDH = 0x2810
const RDT = 0x2818
const TDBAL = 0x3800
const TDBAH = 0x3804
const TDLEN = 0x3808
const TDH = 0x3810
const TDT = 0x3818
const RAL0 = 0x5400
const RAH0 = 0x5404
const MTA = 0x5200

const INT_TXDW = 0x01
const INT_LSC = 0x04
const INT_RXDMT0 = 0x10
const INT_RXO = 0x40
const INT_RXT0 = 0x80

const RX_COUNT = 32
const TX_COUNT = 8
const BUF = 2048

let regs = 0
let pcibdf = nil
func rd(r):
    return uio.peek32(regs + r)
func wr(r, v):
    uio.poke32(regs + r, v)

func hex2(v):
    let d = "0123456789abcdef"
    return d.slice((v >> 4) & 15, ((v >> 4) & 15) + 1) .. d.slice(v & 15, (v & 15) + 1)

# ---- the card ------------------------------------------------------------------------------------------------------------------
let rx_blk = nil
let tx_blk = nil
let rx_cur = 0
let tx_cur = 0
let mac = [0, 0, 0, 0, 0, 0]
let pending_irq = 0
let int_count = 0
let rx_frames = 0
let arp_reply = false
let tx_frames = 0
let sub_pid = 0
let sub_va = 0
let rxq = []
let inflight = false
let inflight_at = 0
let rx_dropped = 0

func card_open():
    let f = pci_find()
    if f == nil:
        return "no E1000 / E1000E on the PCI bus"
    let bdf = f[0]
    pcibdf = bdf
    cfg_w32(bdf, 4, (cfg_r32(bdf, 4) & 0xFFFF) | 7)          # I/O + memory space + bus master
    let bar = cfg_r32(bdf, 0x10)
    let phys = bar & 0xFFFFFFF0
    if ((bar >> 1) & 3) == 2:
        phys = phys | (cfg_r32(bdf, 0x14) << 32)
    regs = uio.mmio_map(phys, 0x20000)
    log("found device 8086:" .. hex2(f[1] >> 8) .. hex2(f[1] & 255) .. " at PCI " .. to_string(bdf[1]) .. ":" .. to_string(bdf[2]))
    wr(IMC, 0xFFFFFFFF)
    wr(CTRL, rd(CTRL) | (1 << 26))                           # reset
    for i in range(100000):
        if (rd(CTRL) & (1 << 26)) == 0:
            break
    wr(IMC, 0xFFFFFFFF)
    rd(ICR)
    wr(CTRL, (rd(CTRL) | 0x40 | 0x20) & ~((1 << 3) | (1 << 31)))   # set link up, auto speed; no LRST / PHY reset
    let lo = rd(RAL0)
    let hi = rd(RAH0)
    for i in range(4):
        mac[i] = (lo >> (8 * i)) & 255
    mac[4] = hi & 255
    mac[5] = (hi >> 8) & 255
    for i in range(128):
        wr(MTA + 4 * i, 0)
    # receive ring
    rx_blk = uio.dma_alloc(RX_COUNT * 16 + RX_COUNT * BUF)
    let bufs = rx_blk[2] + RX_COUNT * 16
    for i in range(RX_COUNT):
        uio.poke64(rx_blk[1] + 16 * i, bufs + BUF * i)
        uio.poke64(rx_blk[1] + 16 * i + 8, 0)
    wr(RDBAL, rx_blk[2] & 0xFFFFFFFF)
    wr(RDBAH, rx_blk[2] >> 32)
    wr(RDLEN, RX_COUNT * 16)
    wr(RDH, 0)
    wr(RDT, RX_COUNT - 1)
    wr(RCTL, (1 << 1) | (1 << 15) | (1 << 26))               # enable, accept broadcast, strip the CRC, 2048-byte buffers
    # transmit ring
    tx_blk = uio.dma_alloc(TX_COUNT * 16 + TX_COUNT * BUF)
    wr(TDBAL, tx_blk[2] & 0xFFFFFFFF)
    wr(TDBAH, tx_blk[2] >> 32)
    wr(TDLEN, TX_COUNT * 16)
    wr(TDH, 0)
    wr(TDT, 0)
    wr(TIPG, 0x0060200A)
    wr(TCTL, (1 << 1) | (1 << 3) | (0x10 << 4) | (0x40 << 12))
    return nil

# queue one frame (an array of byte values, up to 1514) for transmission
func send_frame(data):
    let slot = tx_cur
    let base = tx_blk[1] + 16 * slot
    if tx_frames >= TX_COUNT:                                 # the descriptor must have been used up (descriptor done) before it is reused
        for spin in range(200000):
            if (uio.peek8(base + 12) & 1) != 0:
                break
    let buf = tx_blk[1] + TX_COUNT * 16 + BUF * slot
    for i in range(len(data)):
        uio.poke8(buf + i, data[i])
    uio.poke64(base, tx_blk[2] + TX_COUNT * 16 + BUF * slot)
    uio.poke16(base + 8, len(data))
    uio.poke8(base + 10, 0)
    uio.poke8(base + 11, 0x0B)                                # EOP | IFCS | RS
    uio.poke8(base + 12, 0)
    tx_cur = (tx_cur + 1) % TX_COUNT
    wr(TDT, tx_cur)
    tx_frames += 1
    return true

func cat(parts):
    let out = []
    for p in parts:
        for b in p:
            out.append(b)
    return out

# the frames the card has received since the last call, taken off the ring: [address of the bytes, length] (valid until the next call)
func take_frames():
    let out = []
    while true:
        let d = rx_blk[1] + 16 * rx_cur
        let st = uio.peek8(d + 12)
        if (st & 1) == 0:
            break
        let n = uio.peek16(d + 8)
        if (st & 2) != 0 and n > 0:
            out.append([rx_blk[1] + RX_COUNT * 16 + BUF * rx_cur, n])
        let done = rx_cur
        rx_cur = (rx_cur + 1) % RX_COUNT
        uio.poke8(d + 12, 0)
        wr(RDT, done)
        rx_frames += 1
    return out

func ip_str(a):
    return to_string(a[0]) .. "." .. to_string(a[1]) .. "." .. to_string(a[2]) .. "." .. to_string(a[3])

# an ARP reply for our request?
func look(va, n):
    if n >= 42 and uio.peek8(va + 12) == 8 and uio.peek8(va + 13) == 6 and uio.peek8(va + 21) == 2:
        let m2 = []
        for i in range(6):
            m2.append(hex2(uio.peek8(va + 22 + i)))
        let ip = []
        for i in range(4):
            ip.append(uio.peek8(va + 28 + i))
        log("ARP reply: " .. ip_str(ip) .. " is at " .. m2.join(":"))
        arp_reply = true

# the frames for the subscribed stack: copied off the ring into rxq, handed over one at a time
func queue_frame(va, n):
    if sub_pid == 0:
        return nil
    if len(rxq) >= 64 or n > 1514:
        rx_dropped += 1
        return nil
    let f = []
    f.reserve(n)
    for i in range(n):
        f.append(uio.peek8(va + i))
    rxq.append(f)

func deliver():
    if sub_pid == 0 or inflight or len(rxq) == 0:
        return nil
    let f = rxq.remove_at(0)
    for i in range(len(f)):
        uio.poke8(sub_va + i, f[i])
    inflight = true
    inflight_at = psys.ms()
    ipc.send(sub_pid, "rx\t" .. to_string(len(f)))

# ---- main ------------------------------------------------------------------------------------------------------------------------
let problem = card_open()
let my_ip = [10, 0, 2, 15]
let gw_ip = [10, 0, 2, 2]
let irq_gsi = -1
if problem != nil:
    log("no network: " .. problem)
else:
    log("MAC " .. mac.map(b => hex2(b)).join(":") .. ", link " .. ("up" if (rd(STATUS) & 2) != 0 else "down"))
    let line = cfg_r32(pcibdf, 0x3C) & 255           # the firmware's interrupt line: the I/O APIC input on an i440fx machine (PIIX3 routes PCI pins to irq 10 / 11)
    for g in [line, 16, 17, 18, 19]:
        try:
            ipc.irq_register(g, true)
        catch e:
            pass
    wr(IMS, INT_RXT0 | INT_RXDMT0 | INT_RXO | INT_LSC | INT_TXDW)
    wr(ICS, INT_LSC)                                          # a test interrupt: see where it arrives
ipc.register("net")
let running = true
let started = psys.ms()
let arp_sent = false
while running:
    io.flush()
    let m = ipc.recv_from(true, 500 if problem == nil and not arp_sent else (1000 if inflight else 0))
    if m == nil:
        if inflight and psys.ms() - inflight_at > 2000:
            inflight = false                                  # the stack never answered: do not stall for ever
            deliver()
        # (only before the first interrupt shows up: report it rather than wait for ever)
        if irq_gsi < 0 and not arp_sent:
            log("no interrupt arrived from the card (ICR " .. to_string(rd(ICR)) .. ", IMS " .. to_string(rd(IMS)) .. ", PCI command " .. to_string(cfg_r32(pcibdf, 4) & 0xFFFF) .. ", interrupt line/pin " .. to_string(cfg_r32(pcibdf, 0x3C) & 0xFFFF) .. ")")
        arp_sent = true
        continue
    let src = m[0]
    let q = m[1].split("\t")
    if src == 0:
        let gsi = to_int(q[1])
        int_count += 1
        let cause = rd(ICR)                                   # reading clears it
        if irq_gsi < 0:
            irq_gsi = gsi
            log("interrupt works: card input " .. to_string(gsi) .. " (cause " .. to_string(cause) .. ")")
        for f in take_frames():
            look(f[0], f[1])
            queue_frame(f[0], f[1])
        ipc.irq_ack(gsi)
        deliver()
        if not arp_sent and irq_gsi >= 0:
            arp_sent = true
            # who has 10.0.2.2? (QEMU's user-mode network answers for its gateway)
            send_frame(cat([[255, 255, 255, 255, 255, 255], mac, [8, 6, 0, 1, 8, 0, 6, 4, 0, 1], mac, my_ip, [0, 0, 0, 0, 0, 0], gw_ip]))
        continue
    if q[0] == "mac":
        ipc.send(src, "ok\t" .. mac.map(b => hex2(b)).join(":"))
    elif q[0] == "stats":
        ipc.send(src, "ok\t" .. to_string(int_count) .. "\t" .. to_string(rx_frames) .. "\t" .. to_string(tx_frames) .. "\t" .. to_string(rx_dropped))
    elif q[0] == "sub":
        if problem != nil:
            ipc.send(src, "err\t" .. problem)
        else:
            let seg = ipc.shm_open(to_int(q[1]))
            if seg[1] < 4096:
                ipc.send(src, "err\tsegment too small")
            else:
                sub_pid = src
                sub_va = seg[0]
                rxq = []
                inflight = false
                ipc.send(src, "ok\t" .. mac.map(b => hex2(b)).join(":"))
    elif q[0] == "tx" and src == sub_pid:
        let n = to_int(q[1])
        if n == nil or n < 14 or n > 1514:
            ipc.send(src, "err\tbad length")
        else:
            let f = []
            f.reserve(n)
            for i in range(n):
                f.append(uio.peek8(sub_va + 2048 + i))
            send_frame(f)
            ipc.send(src, "ok")
    elif q[0] == "ack" and src == sub_pid:
        inflight = false
        deliver()
    elif q[0] == "unsub" and src == sub_pid:
        sub_pid = 0
        rxq = []
        inflight = false
        ipc.send(src, "ok")
    elif q[0] == "quit":
        ipc.send(src, "ok")
        running = false
log("bye")
