# sprintmp3: an MPEG audio Layer III (MP3) decoder written in Sprint, a port of minimp3 (CC0, by lieff et al.).
#
#   import sprintmp3
#   let a = sprintmp3.decode(bytes)   # bytes: string, array of ints 0..255 or typed.u8 (fs.read_bytes)
#   a.sample_rate, a.channels         # Hz, 1 or 2
#   a.samples                         # typed.i16, interleaved, a.frames * a.channels values
#   a.frames                          # samples per channel
#   sprintmp3.info(bytes)             # {sample_rate, channels, bitrate_kbps, layer, frames, samples} (headers only, no decode)
#   let d = sprintmp3.Decoder()       # streaming: d.decode_frame(typed.u8, offset, bytes_left) -> {samples, frame_bytes, ...}
#
# MPEG-1 / 2 / 2.5 Layer III, mono / stereo / joint (MS + intensity) stereo, long / short / mixed blocks, bit reservoir, free
# format, CRC frames, ID3v2 / ID3v1 / Xing / Info tags are skipped. Layers I and II are not supported (frames are skipped).
# The arithmetic is done in double precision; the output follows minimp3 (round half away from zero, clipped to int16), and
# differs from a float32 decoder by at most a few LSB.
import typed
import math
import mp3tab

let SHORT_BLOCK_TYPE = 2
let STOP_BLOCK_TYPE = 3
let MAX_RESERV = 511
let MAX_FRAME = 2304

func fail(msg):
    throw error("ValueError", msg)

func imin(a, b):
    return a if a < b else b

func imax(a, b):
    return a if a > b else b

func as_u8(d):
    if type(d) == "native":
        return d
    let n = len(d)
    let r = typed.u8(n)
    for i in range(n):
        r[i] = d[i]
    return r

# ---------------------------------------------------------------------------------------------------------------------
# frame header helpers: h is the buffer, o the offset of the 4 header bytes
# ---------------------------------------------------------------------------------------------------------------------
func hdr_is_mono(h, o):
    return (h[o + 3] & 0xc0) == 0xc0

func hdr_is_ms(h, o):
    return (h[o + 3] & 0xe0) == 0x60

func hdr_free_format(h, o):
    return (h[o + 2] & 0xf0) == 0

func hdr_is_crc(h, o):
    return (h[o + 1] & 1) == 0

func hdr_padding_bit(h, o):
    return (h[o + 2] & 2) != 0

func hdr_mpeg1(h, o):
    return (h[o + 1] & 8) != 0

func hdr_not_mpeg25(h, o):
    return (h[o + 1] & 0x10) != 0

func hdr_layer(h, o):
    return (h[o + 1] >> 1) & 3

func hdr_bitrate_idx(h, o):
    return h[o + 2] >> 4

func hdr_sr_idx(h, o):
    return (h[o + 2] >> 2) & 3

func hdr_my_sr(h, o):
    return hdr_sr_idx(h, o) + (((h[o + 1] >> 3) & 1) + ((h[o + 1] >> 4) & 1)) * 3

func hdr_frame_576(h, o):
    return (h[o + 1] & 14) == 2

func hdr_layer1(h, o):
    return (h[o + 1] & 6) == 6

func hdr_valid(h, o):
    return h[o] == 0xff and ((h[o + 1] & 0xf0) == 0xf0 or (h[o + 1] & 0xfe) == 0xe2) and hdr_layer(h, o) != 0 and hdr_bitrate_idx(h, o) != 15 and hdr_sr_idx(h, o) != 3

func hdr_compare(h1, o1, h2, o2):
    return hdr_valid(h2, o2) and ((h1[o1 + 1] ^ h2[o2 + 1]) & 0xfe) == 0 and ((h1[o1 + 2] ^ h2[o2 + 2]) & 0x0c) == 0 and hdr_free_format(h1, o1) == hdr_free_format(h2, o2)

func hdr_bitrate_kbps(h, o):
    let m = 1 if hdr_mpeg1(h, o) else 0
    return 2 * mp3tab.halfrate[(m * 3 + hdr_layer(h, o) - 1) * 15 + hdr_bitrate_idx(h, o)]

func hdr_hz(h, o):
    let hz = [44100, 48000, 32000][hdr_sr_idx(h, o)]
    if not hdr_mpeg1(h, o):
        hz = hz >> 1
    if not hdr_not_mpeg25(h, o):
        hz = hz >> 1
    return hz

func hdr_frame_samples(h, o):
    if hdr_layer1(h, o):
        return 384
    return 576 if hdr_frame_576(h, o) else 1152

func hdr_frame_bytes(h, o, free_size):
    let fb = hdr_frame_samples(h, o) * hdr_bitrate_kbps(h, o) * 125 // hdr_hz(h, o)
    if hdr_layer1(h, o):
        fb = fb & (~3)
    return fb if fb != 0 else free_size

func hdr_padding(h, o):
    if hdr_padding_bit(h, o):
        return 4 if hdr_layer1(h, o) else 1
    return 0

func hdr_is_null_or_tag(h, o, left):
    if h[o] == 0 and h[o + 1] == 0 and h[o + 2] == 0 and h[o + 3] == 0:
        return true
    return left == 128 and h[o] == 0x54 and h[o + 1] == 0x41 and h[o + 2] == 0x47

func match_frame(h, o, bytes, frame_bytes):
    let i = 0
    let nmatch = 0
    while nmatch < 10:
        i += hdr_frame_bytes(h, o + i, frame_bytes) + hdr_padding(h, o + i)
        if i + 4 > bytes:
            return nmatch > 0
        if hdr_is_null_or_tag(h, o + i, bytes - i):
            return nmatch > 0
        if not hdr_compare(h, o, h, o + i):
            return false
        nmatch += 1
    return true

# -> [offset, frame_bytes_incl_padding, free_format_bytes]
func find_frame(m, base, n, free_fmt):
    let i = 0
    while i < n - 4:
        let o = base + i
        if hdr_valid(m, o):
            let fb = hdr_frame_bytes(m, o, free_fmt)
            let fap = fb + hdr_padding(m, o)
            let k = 4
            while fb == 0 and k < 2304 and i + 2 * k < n - 4:
                if hdr_compare(m, o, m, o + k):
                    let f2 = k - hdr_padding(m, o)
                    let nf = f2 + hdr_padding(m, o + k)
                    if not (i + k + nf + 4 > n or not hdr_compare(m, o, m, o + k + nf)):
                        fap = k
                        fb = f2
                        free_fmt = f2
                k += 1
            if (fb != 0 and i + fap <= n and match_frame(m, o, n - i, fb)) or (i == 0 and fap == n):
                return [i, fap, free_fmt]
            free_fmt = 0
        i += 1
    return [n, 0, free_fmt]

# ---------------------------------------------------------------------------------------------------------------------
# bit reader over a typed.u8 (the buffer must have >= 4 spare bytes after the data)
# ---------------------------------------------------------------------------------------------------------------------
func get_bits(bs, n):
    let pos = bs.pos
    bs.pos = pos + n
    if bs.pos > bs.limit:
        return 0
    let p = pos >> 3
    let s = pos & 7
    let need = n + s
    let nb = (need + 7) >> 3
    let acc = 0
    let buf = bs.buf
    for i in range(nb):
        acc = (acc << 8) | buf[p + i]
    acc = acc >> (nb * 8 - need)
    return acc & ((1 << n) - 1)

func peek_bits(buf, pos, n):
    let p = pos >> 3
    let v = (buf[p] << 24) | (buf[p + 1] << 16) | (buf[p + 2] << 8) | buf[p + 3]
    v = (v << (pos & 7)) & 0xffffffff
    return v >> (32 - n)

# ---------------------------------------------------------------------------------------------------------------------
# Layer III
# ---------------------------------------------------------------------------------------------------------------------
func new_gr():
    return {sfbtab: mp3tab.g_scf_long[0], part_23_length: 0, big_values: 0, scalefac_compress: 0, global_gain: 0, block_type: 0, mixed_block_flag: 0, n_long_sfb: 0, n_short_sfb: 0, table_select: [0, 0, 0], region_count: [0, 0, 0], subblock_gain: [0, 0, 0], preflag: 0, scalefac_scale: 0, count1_table: 0, scfsi: 0}

# returns main_data_begin, or -1; fills gr[0..]
func read_side_info(bs, gr, h, o):
    let scfsi = 0
    let part_23_sum = 0
    let gr_count = 1 if hdr_is_mono(h, o) else 2
    let sr_idx = hdr_my_sr(h, o)
    if sr_idx != 0:
        sr_idx -= 1
    let mpeg1 = hdr_mpeg1(h, o)
    let main_data_begin = 0
    if mpeg1:
        gr_count *= 2
        main_data_begin = get_bits(bs, 9)
        scfsi = get_bits(bs, 7 + gr_count)
    else:
        main_data_begin = get_bits(bs, 8 + gr_count) >> gr_count
    let gi = 0
    while gr_count > 0:
        let g = gr[gi]
        if hdr_is_mono(h, o):
            scfsi = scfsi << 4
        g.part_23_length = get_bits(bs, 12)
        part_23_sum += g.part_23_length
        g.big_values = get_bits(bs, 9)
        if g.big_values > 288:
            return -1
        g.global_gain = get_bits(bs, 8)
        g.scalefac_compress = get_bits(bs, 4 if mpeg1 else 9)
        g.sfbtab = mp3tab.g_scf_long[sr_idx]
        g.n_long_sfb = 22
        g.n_short_sfb = 0
        let tables = 0
        if get_bits(bs, 1) != 0:
            g.block_type = get_bits(bs, 2)
            if g.block_type == 0:
                return -1
            g.mixed_block_flag = get_bits(bs, 1)
            g.region_count[0] = 7
            g.region_count[1] = 255
            if g.block_type == SHORT_BLOCK_TYPE:
                scfsi = scfsi & 0x0f0f
                if g.mixed_block_flag == 0:
                    g.region_count[0] = 8
                    g.sfbtab = mp3tab.g_scf_short[sr_idx]
                    g.n_long_sfb = 0
                    g.n_short_sfb = 39
                else:
                    g.sfbtab = mp3tab.g_scf_mixed[sr_idx]
                    g.n_long_sfb = 8 if mpeg1 else 6
                    g.n_short_sfb = 30
            tables = get_bits(bs, 10)
            tables = tables << 5
            g.subblock_gain[0] = get_bits(bs, 3)
            g.subblock_gain[1] = get_bits(bs, 3)
            g.subblock_gain[2] = get_bits(bs, 3)
        else:
            g.block_type = 0
            g.mixed_block_flag = 0
            tables = get_bits(bs, 15)
            g.region_count[0] = get_bits(bs, 4)
            g.region_count[1] = get_bits(bs, 3)
            g.region_count[2] = 255
        g.table_select[0] = tables >> 10
        g.table_select[1] = (tables >> 5) & 31
        g.table_select[2] = tables & 31
        g.preflag = get_bits(bs, 1) if mpeg1 else (1 if g.scalefac_compress >= 500 else 0)
        g.scalefac_scale = get_bits(bs, 1)
        g.count1_table = get_bits(bs, 1)
        g.scfsi = (scfsi >> 12) & 15
        scfsi = scfsi << 4
        gi += 1
        gr_count -= 1
    if part_23_sum + bs.pos > bs.limit + main_data_begin * 8:
        return -1
    return main_data_begin

# scf: typed.i32 (iscf), ist: typed.u8 (a channel's ist_pos); counts: row + offset
func read_scalefactors(scf, ist, scf_size, cnt_row, cnt_off, bs, scfsi):
    let pos = 0
    let i = 0
    while i < 4 and cnt_row[cnt_off + i] != 0:
        let cnt = cnt_row[cnt_off + i]
        if (scfsi & 8) != 0:
            for k in range(cnt):
                scf[pos + k] = ist[pos + k]
        else:
            let bits = scf_size[i]
            if bits == 0:
                for k in range(cnt):
                    scf[pos + k] = 0
                    ist[pos + k] = 0
            else:
                let max_scf = (1 << bits) - 1 if scfsi < 0 else -1
                for k in range(cnt):
                    let s = get_bits(bs, bits)
                    ist[pos + k] = 255 if s == max_scf else s
                    scf[pos + k] = s
        pos += cnt
        i += 1
        scfsi = scfsi * 2
    scf[pos] = 0
    scf[pos + 1] = 0
    scf[pos + 2] = 0

func ldexp_q2(y, q):
    return y * (2.0 ** (-q / 4.0))

# scf: typed.f64 (40)
func decode_scalefactors(h, o, ist, bs, g, scf, ch):
    let part_idx = (1 if g.n_short_sfb != 0 else 0) + (1 if g.n_long_sfb == 0 else 0)
    let row = mp3tab.g_scf_partitions[part_idx]
    let off = 0
    let scf_size = [0, 0, 0, 0]
    let iscf = typed.i32(48)
    let scf_shift = g.scalefac_scale + 1
    let scfsi = g.scfsi
    if hdr_mpeg1(h, o):
        let part = mp3tab.g_scfc_decode[g.scalefac_compress]
        scf_size[0] = part >> 2
        scf_size[1] = part >> 2
        scf_size[2] = part & 3
        scf_size[3] = part & 3
    else:
        let ist_flag = 1 if ((h[o + 3] & 0x10) != 0 and ch != 0) else 0
        let sfc = g.scalefac_compress >> ist_flag
        let k = ist_flag * 3 * 4
        let modprod = 1
        while sfc >= 0:
            modprod = 1
            let i = 3
            while i >= 0:
                scf_size[i] = sfc // modprod % mp3tab.g_mod[k + i]
                modprod *= mp3tab.g_mod[k + i]
                i -= 1
            sfc -= modprod
            k += 4
        off = k
        scfsi = -16
    read_scalefactors(iscf, ist, scf_size, row, off, bs, scfsi)
    if g.n_short_sfb != 0:
        let sh = 3 - scf_shift
        let i = 0
        while i < g.n_short_sfb:
            iscf[g.n_long_sfb + i + 0] += g.subblock_gain[0] << sh
            iscf[g.n_long_sfb + i + 1] += g.subblock_gain[1] << sh
            iscf[g.n_long_sfb + i + 2] += g.subblock_gain[2] << sh
            i += 3
    elif g.preflag != 0:
        for i in range(10):
            iscf[11 + i] += mp3tab.g_preamp[i]
    let gain_exp = g.global_gain - 4 - 210 - (2 if hdr_is_ms(h, o) else 0)
    let gain = ldexp_q2(2048.0, 44 - gain_exp)
    for i in range(g.n_long_sfb + g.n_short_sfb):
        scf[i] = ldexp_q2(gain, iscf[i] << scf_shift)

let POW43 = typed.f64(8208)
for i in range(8208):
    POW43[i] = (i * 1.0) ** (4.0 / 3.0)

func sfb_at(row, i):
    return row[i] if i < len(row) else 0

# dst: typed.f64, dst_off; scf: typed.f64
func huffman(dst, di, bs, g, scf, limit):
    let buf = bs.buf
    let tabs = mp3tab.tabs
    let tabindex = mp3tab.tabindex
    let linbits_t = mp3tab.g_linbits
    let sfb = g.sfbtab
    let si = 0
    let sci = 0
    let one = 0.0
    let ireg = 0
    let big_val_cnt = g.big_values
    let pos = bs.pos
    let np = 0
    while big_val_cnt > 0:
        let tab_num = g.table_select[ireg]
        let sfb_cnt = g.region_count[ireg]
        ireg += 1
        let cb = tabindex[tab_num]
        let linbits = linbits_t[tab_num]
        let go = true
        while go:
            np = sfb_at(sfb, si) // 2
            si += 1
            let pairs = imin(big_val_cnt, np)
            one = scf[sci]
            sci += 1
            while pairs > 0:
                let w = 5
                let leaf = tabs[cb + peek_bits(buf, pos, w)]
                while leaf < 0:
                    pos += w
                    w = leaf & 7
                    leaf = tabs[cb + peek_bits(buf, pos, w) - (leaf >> 3)]
                pos += leaf >> 8
                for j in range(2):
                    let lsb = leaf & 15
                    if linbits != 0 and lsb == 15:
                        lsb += peek_bits(buf, pos, linbits)
                        pos += linbits
                    let neg = lsb != 0 and peek_bits(buf, pos, 1) == 1
                    let v = POW43[lsb] * one
                    dst[di] = -v if neg else v
                    di += 1
                    leaf = leaf >> 4
                    if lsb != 0:
                        pos += 1
                pairs -= 1
            big_val_cnt -= np
            if np == 0:
                go = false
            elif big_val_cnt > 0:
                sfb_cnt -= 1
                go = sfb_cnt >= 0
            else:
                go = false
        if np == 0:
            big_val_cnt = 0
    let cb1 = mp3tab.tab33 if g.count1_table != 0 else mp3tab.tab32
    np = 1 - big_val_cnt
    while true:
        let leaf = cb1[peek_bits(buf, pos, 4)]
        if (leaf & 8) == 0:
            leaf = cb1[(leaf >> 3) + peek_bits(buf, pos + 4, leaf & 3)]
        pos += leaf & 7
        if pos > limit:
            break
        np -= 1
        if np == 0:
            np = sfb_at(sfb, si) // 2
            si += 1
            if np == 0:
                break
            one = scf[sci]
            sci += 1
        if (leaf & 128) != 0:
            dst[di] = -one if peek_bits(buf, pos, 1) == 1 else one
            pos += 1
        if (leaf & 64) != 0:
            dst[di + 1] = -one if peek_bits(buf, pos, 1) == 1 else one
            pos += 1
        np -= 1
        if np == 0:
            np = sfb_at(sfb, si) // 2
            si += 1
            if np == 0:
                break
            one = scf[sci]
            sci += 1
        if (leaf & 32) != 0:
            dst[di + 2] = -one if peek_bits(buf, pos, 1) == 1 else one
            pos += 1
        if (leaf & 16) != 0:
            dst[di + 3] = -one if peek_bits(buf, pos, 1) == 1 else one
            pos += 1
        di += 4
    bs.pos = limit

func midside(buf, l, n):
    for i in range(n):
        let a = buf[l + i]
        let b = buf[l + 576 + i]
        buf[l + i] = a + b
        buf[l + 576 + i] = a - b

func intensity_band(buf, l, n, kl, kr):
    for i in range(n):
        buf[l + 576 + i] = buf[l + i] * kr
        buf[l + i] = buf[l + i] * kl

func stereo_top_band(buf, r, sfb, sfb_off, nbands, max_band):
    max_band[0] = -1
    max_band[1] = -1
    max_band[2] = -1
    for i in range(nbands):
        let k = 0
        let w = sfb[sfb_off + i]
        while k < w:
            if buf[r + k] != 0 or buf[r + k + 1] != 0:
                max_band[i % 3] = i
                break
            k += 2
        r += w

func stereo_process(buf, ist, sfb, h, o, max_band, mpeg2_sh):
    let mpeg1 = hdr_mpeg1(h, o)
    let max_pos = 7 if mpeg1 else 64
    let left = 0
    let i = 0
    let ms = hdr_is_ms(h, o)
    while sfb[i] != 0:
        let ipos = ist[i]
        if i > max_band[i % 3] and ipos < max_pos:
            let s = 1.41421356 if ms else 1.0
            let kl = 1.0
            let kr = 1.0
            if mpeg1:
                kl = mp3tab.g_pan[2 * ipos]
                kr = mp3tab.g_pan[2 * ipos + 1]
            else:
                kr = ldexp_q2(1.0, ((ipos + 1) >> 1) << mpeg2_sh)
                if (ipos & 1) != 0:
                    kl = kr
                    kr = 1.0
            intensity_band(buf, left, sfb[i], kl * s, kr * s)
        elif ms:
            midside(buf, left, sfb[i])
        left += sfb[i]
        i += 1

func intensity_stereo(buf, ist, grs, gi, h, o):
    let g = grs[gi]
    let max_band = [0, 0, 0]
    let n_sfb = g.n_long_sfb + g.n_short_sfb
    let max_blocks = 3 if g.n_short_sfb != 0 else 1
    stereo_top_band(buf, 576, g.sfbtab, 0, n_sfb, max_band)
    if g.n_long_sfb != 0:
        let m = imax(imax(max_band[0], max_band[1]), max_band[2])
        max_band[0] = m
        max_band[1] = m
        max_band[2] = m
    for i in range(max_blocks):
        let default_pos = 3 if hdr_mpeg1(h, o) else 0
        let itop = n_sfb - max_blocks + i
        let prev = itop - max_blocks
        ist[itop] = default_pos if max_band[i] >= prev else ist[prev]
    stereo_process(buf, ist, g.sfbtab, h, o, max_band, grs[gi + 1].scalefac_compress & 1)

func reorder(buf, base, scratch, sfb, sfb_off):
    let src = base
    let dst = 0
    let sp = sfb_off
    let ln = sfb[sp]
    while ln != 0:
        for i in range(ln):
            scratch[dst] = buf[src]
            scratch[dst + 1] = buf[src + ln]
            scratch[dst + 2] = buf[src + 2 * ln]
            dst += 3
            src += 1
        src += 2 * ln
        sp += 3
        ln = sfb[sp]
    for i in range(dst):
        buf[base + i] = scratch[i]

func antialias(buf, base, nbands):
    while nbands > 0:
        for i in range(8):
            let u = buf[base + 18 + i]
            let d = buf[base + 17 - i]
            buf[base + 18 + i] = u * mp3tab.g_aa[i] - d * mp3tab.g_aa[8 + i]
            buf[base + 17 - i] = u * mp3tab.g_aa[8 + i] + d * mp3tab.g_aa[i]
        base += 18
        nbands -= 1

func dct3_9(y):
    let s0 = y[0]
    let s2 = y[2]
    let s4 = y[4]
    let s6 = y[6]
    let s8 = y[8]
    let t0 = s0 + s6 * 0.5
    s0 -= s6
    let t4 = (s4 + s2) * 0.93969262
    let t2 = (s8 + s2) * 0.76604444
    s6 = (s4 - s8) * 0.17364818
    s4 += s8 - s2
    s2 = s0 - s4 * 0.5
    y[4] = s4 + s0
    s8 = t0 - t2 + s6
    s0 = t0 - t4 + t2
    s4 = t0 + t4 - s6
    let s1 = y[1]
    let s3 = y[3]
    let s5 = y[5]
    let s7 = y[7]
    s3 *= 0.86602540
    t0 = (s5 + s1) * 0.98480775
    t4 = (s5 - s7) * 0.34202014
    t2 = (s1 + s7) * 0.64278761
    s1 = (s1 - s5 - s7) * 0.86602540
    s5 = t0 - s3 - t2
    s7 = t4 - s3 - t0
    s3 = t4 + s3 - t2
    y[0] = s4 - s7
    y[1] = s2 + s1
    y[2] = s0 - s3
    y[3] = s8 + s5
    y[5] = s8 - s5
    y[6] = s0 + s3
    y[7] = s2 - s1
    y[8] = s4 + s7

let CO9 = typed.f64(9)
let SI9 = typed.f64(9)

# window: offset into mp3tab.g_mdct_window (0 or 18)
func imdct36(buf, base, ovl, ovo, win, nbands):
    let tw = mp3tab.g_twid9
    let wn = mp3tab.g_mdct_window
    let co = CO9
    let si = SI9
    for j in range(nbands):
        let gb = base + j * 18
        let ob = ovo + j * 9
        co[0] = -buf[gb]
        si[0] = buf[gb + 17]
        for i in range(4):
            si[8 - 2 * i] = buf[gb + 4 * i + 1] - buf[gb + 4 * i + 2]
            co[1 + 2 * i] = buf[gb + 4 * i + 1] + buf[gb + 4 * i + 2]
            si[7 - 2 * i] = buf[gb + 4 * i + 4] - buf[gb + 4 * i + 3]
            co[2 + 2 * i] = -(buf[gb + 4 * i + 3] + buf[gb + 4 * i + 4])
        dct3_9(co)
        dct3_9(si)
        si[1] = -si[1]
        si[3] = -si[3]
        si[5] = -si[5]
        si[7] = -si[7]
        for i in range(9):
            let ov = ovl[ob + i]
            let sum = co[i] * tw[9 + i] + si[i] * tw[i]
            ovl[ob + i] = co[i] * tw[i] - si[i] * tw[9 + i]
            buf[gb + i] = ov * wn[win + i] - sum * wn[win + 9 + i]
            buf[gb + 17 - i] = ov * wn[win + 9 + i] + sum * wn[win + i]

func idct3(x0, x1, x2, dst):
    let m1 = x1 * 0.86602540
    let a1 = x0 - x2 * 0.5
    dst[1] = x0 + x2
    dst[0] = a1 + m1
    dst[2] = a1 - m1

let CO3 = typed.f64(3)
let SI3 = typed.f64(3)

# x: array, xo: offset; dst: buf, do_: offset; ovl, oo
func imdct12(x, xo, dst, do_, ovl, oo):
    let tw = mp3tab.g_twid3
    idct3(-x[xo], x[xo + 6] + x[xo + 3], x[xo + 12] + x[xo + 9], CO3)
    idct3(x[xo + 15], x[xo + 12] - x[xo + 9], x[xo + 6] - x[xo + 3], SI3)
    SI3[1] = -SI3[1]
    for i in range(3):
        let ov = ovl[oo + i]
        let sum = CO3[i] * tw[3 + i] + SI3[i] * tw[i]
        ovl[oo + i] = CO3[i] * tw[i] - SI3[i] * tw[3 + i]
        dst[do_ + i] = ov * tw[2 - i] - sum * tw[5 - i]
        dst[do_ + 5 - i] = ov * tw[5 - i] + sum * tw[2 - i]

let TMP18 = typed.f64(18)

func imdct_short(buf, base, ovl, ovo, nbands):
    while nbands > 0:
        for i in range(18):
            TMP18[i] = buf[base + i]
        for i in range(6):
            buf[base + i] = ovl[ovo + i]
        imdct12(TMP18, 0, buf, base + 6, ovl, ovo + 6)
        imdct12(TMP18, 1, buf, base + 12, ovl, ovo + 6)
        imdct12(TMP18, 2, ovl, ovo, ovl, ovo + 6)
        ovo += 9
        base += 18
        nbands -= 1

func change_sign(buf, base):
    let b = 0
    base += 18
    while b < 32:
        let i = 1
        while i < 18:
            buf[base + i] = -buf[base + i]
            i += 2
        b += 2
        base += 36

func imdct_gr(buf, base, ovl, ovo, block_type, n_long_bands):
    if n_long_bands != 0:
        imdct36(buf, base, ovl, ovo, 0, n_long_bands)
        base += 18 * n_long_bands
        ovo += 9 * n_long_bands
    if block_type == SHORT_BLOCK_TYPE:
        imdct_short(buf, base, ovl, ovo, 32 - n_long_bands)
    else:
        imdct36(buf, base, ovl, ovo, 18 if block_type == STOP_BLOCK_TYPE else 0, 32 - n_long_bands)

# ---------------------------------------------------------------------------------------------------------------------
# synthesis filterbank
# ---------------------------------------------------------------------------------------------------------------------
let DT = typed.f64(32)

func dct_ii(buf, base, n):
    let g_sec = mp3tab.g_sec
    let t = DT
    for k in range(n):
        let y = base + k
        for i in range(8):
            let x0 = buf[y + i * 18]
            let x1 = buf[y + (15 - i) * 18]
            let x2 = buf[y + (16 + i) * 18]
            let x3 = buf[y + (31 - i) * 18]
            let t0 = x0 + x3
            let t1 = x1 + x2
            let t2 = (x1 - x2) * g_sec[3 * i + 0]
            let t3 = (x0 - x3) * g_sec[3 * i + 1]
            t[i] = t0 + t1
            t[8 + i] = (t0 - t1) * g_sec[3 * i + 2]
            t[16 + i] = t3 + t2
            t[24 + i] = (t3 - t2) * g_sec[3 * i + 2]
        for q in range(4):
            let x = q * 8
            let x0 = t[x]
            let x1 = t[x + 1]
            let x2 = t[x + 2]
            let x3 = t[x + 3]
            let x4 = t[x + 4]
            let x5 = t[x + 5]
            let x6 = t[x + 6]
            let x7 = t[x + 7]
            let xt = x0 - x7
            x0 += x7
            x7 = x1 - x6
            x1 += x6
            x6 = x2 - x5
            x2 += x5
            x5 = x3 - x4
            x3 += x4
            x4 = x0 - x3
            x0 += x3
            x3 = x1 - x2
            x1 += x2
            t[x] = x0 + x1
            t[x + 4] = (x0 - x1) * 0.70710677
            x5 = x5 + x6
            x6 = (x6 + x7) * 0.70710677
            x7 = x7 + xt
            x3 = (x3 + x4) * 0.70710677
            x5 -= x7 * 0.198912367
            x7 += x5 * 0.382683432
            x5 -= x7 * 0.198912367
            x0 = xt - x6
            xt += x6
            t[x + 1] = (xt + x7) * 0.50979561
            t[x + 2] = (x4 + x3) * 0.54119611
            t[x + 3] = (x0 - x5) * 0.60134488
            t[x + 5] = (x0 + x5) * 0.89997619
            t[x + 6] = (x4 - x3) * 1.30656302
            t[x + 7] = (xt - x7) * 2.56291556
        for i in range(7):
            buf[y + (4 * i) * 18] = t[i]
            buf[y + (4 * i + 1) * 18] = t[16 + i] + t[24 + i] + t[24 + i + 1]
            buf[y + (4 * i + 2) * 18] = t[8 + i] + t[8 + i + 1]
            buf[y + (4 * i + 3) * 18] = t[16 + i + 1] + t[24 + i] + t[24 + i + 1]
        buf[y + 28 * 18] = t[7]
        buf[y + 29 * 18] = t[16 + 7] + t[24 + 7]
        buf[y + 30 * 18] = t[8 + 7]
        buf[y + 31 * 18] = t[24 + 7]

func scale_pcm(s):
    if s >= 32766.5:
        return 32767
    if s <= -32767.5:
        return -32768
    let v = math.trunc(s + 0.5)
    if v < 0:
        v -= 1
    return v

func synth_pair(pcm, po, nch, z, zo):
    let a = (z[zo + 14 * 64] - z[zo]) * 29
    a += (z[zo + 1 * 64] + z[zo + 13 * 64]) * 213
    a += (z[zo + 12 * 64] - z[zo + 2 * 64]) * 459
    a += (z[zo + 3 * 64] + z[zo + 11 * 64]) * 2037
    a += (z[zo + 10 * 64] - z[zo + 4 * 64]) * 5153
    a += (z[zo + 5 * 64] + z[zo + 9 * 64]) * 6574
    a += (z[zo + 8 * 64] - z[zo + 6 * 64]) * 37489
    a += z[zo + 7 * 64] * 75038
    pcm[po] = scale_pcm(a)
    zo += 2
    a = z[zo + 14 * 64] * 104
    a += z[zo + 12 * 64] * 1567
    a += z[zo + 10 * 64] * 9727
    a += z[zo + 8 * 64] * 64019
    a += z[zo + 6 * 64] * -9975
    a += z[zo + 4 * 64] * -45
    a += z[zo + 2 * 64] * 146
    a += z[zo + 0 * 64] * -5
    pcm[po + 16 * nch] = scale_pcm(a)

let SA = typed.f64(4)
let SB = typed.f64(4)

# xl: grbuf offset of the left channel's data (+ i); lins: workspace, lo = its offset
func synth(buf, xl, pcm, dl, nch, lins, lo):
    let xr = xl + 576 * (nch - 1)
    let dr = dl + (nch - 1)
    let g_win = mp3tab.g_win
    let zlin = lo + 15 * 64
    lins[zlin + 4 * 15] = buf[xl + 18 * 16]
    lins[zlin + 4 * 15 + 1] = buf[xr + 18 * 16]
    lins[zlin + 4 * 15 + 2] = buf[xl]
    lins[zlin + 4 * 15 + 3] = buf[xr]
    lins[zlin + 4 * 31] = buf[xl + 1 + 18 * 16]
    lins[zlin + 4 * 31 + 1] = buf[xr + 1 + 18 * 16]
    lins[zlin + 4 * 31 + 2] = buf[xl + 1]
    lins[zlin + 4 * 31 + 3] = buf[xr + 1]
    synth_pair(pcm, dr, nch, lins, lo + 4 * 15 + 1)
    synth_pair(pcm, dr + 32 * nch, nch, lins, lo + 4 * 15 + 64 + 1)
    synth_pair(pcm, dl, nch, lins, lo + 4 * 15)
    synth_pair(pcm, dl + 32 * nch, nch, lins, lo + 4 * 15 + 64)
    let a = SA
    let b = SB
    let i = 14
    while i >= 0:
        lins[zlin + 4 * i] = buf[xl + 18 * (31 - i)]
        lins[zlin + 4 * i + 1] = buf[xr + 18 * (31 - i)]
        lins[zlin + 4 * i + 2] = buf[xl + 1 + 18 * (31 - i)]
        lins[zlin + 4 * i + 3] = buf[xr + 1 + 18 * (31 - i)]
        lins[zlin + 4 * (i + 16)] = buf[xl + 1 + 18 * (1 + i)]
        lins[zlin + 4 * (i + 16) + 1] = buf[xr + 1 + 18 * (1 + i)]
        lins[zlin + 4 * (i - 16) + 2] = buf[xl + 18 * (1 + i)]
        lins[zlin + 4 * (i - 16) + 3] = buf[xr + 18 * (1 + i)]
        for k in range(8):
            let vzo = zlin + 4 * i - k * 64
            let vyo = zlin + 4 * i - (15 - k) * 64
            # the windows are laid out row by row: row i holds the 16 coefficients (8 pairs) for this i
            let w0 = g_win[(14 - i) * 16 + 2 * k]
            let w1 = g_win[(14 - i) * 16 + 2 * k + 1]
            for j in range(4):
                let vz = lins[vzo + j]
                let vy = lins[vyo + j]
                if k == 0:
                    b[j] = vz * w1 + vy * w0
                    a[j] = vz * w0 - vy * w1
                elif k % 2 == 1:
                    b[j] += vz * w1 + vy * w0
                    a[j] += vy * w1 - vz * w0
                else:
                    b[j] += vz * w1 + vy * w0
                    a[j] += vz * w0 - vy * w1
        pcm[dr + (15 - i) * nch] = scale_pcm(a[1])
        pcm[dr + (17 + i) * nch] = scale_pcm(b[1])
        pcm[dl + (15 - i) * nch] = scale_pcm(a[0])
        pcm[dl + (17 + i) * nch] = scale_pcm(b[0])
        pcm[dr + (47 - i) * nch] = scale_pcm(a[3])
        pcm[dr + (49 + i) * nch] = scale_pcm(b[3])
        pcm[dl + (47 - i) * nch] = scale_pcm(a[2])
        pcm[dl + (49 + i) * nch] = scale_pcm(b[2])
        i -= 1

func synth_granule(qmf, buf, nbands, nch, pcm, po, lins):
    for i in range(nch):
        dct_ii(buf, 576 * i, nbands)
    for i in range(15 * 64):
        lins[i] = qmf[i]
    for i in range(64 * nbands):
        lins[15 * 64 + i] = 0.0
    let i = 0
    while i < nbands:
        synth(buf, i, pcm, po + 32 * nch * i, nch, lins, i * 64)
        i += 2
    if nch == 1:
        i = 0
        while i < 15 * 64:
            qmf[i] = lins[nbands * 64 + i]
            i += 2
    else:
        for i in range(15 * 64):
            qmf[i] = lins[nbands * 64 + i]

# ---------------------------------------------------------------------------------------------------------------------
# decoder
# ---------------------------------------------------------------------------------------------------------------------
export func Decoder():
    let dec = {header: typed.u8(4), free_format_bytes: 0, reserv: 0, reserv_buf: typed.u8(MAX_RESERV + 8), mdct_overlap: typed.f64(2 * 288 + 16), qmf_state: typed.f64(15 * 64 + 64)}
    let maindata = typed.u8(MAX_RESERV + MAX_FRAME + 16)
    let grbuf = typed.f64(2 * 576 + 32)
    let scf = typed.f64(48)
    let syn = typed.f64((18 + 15) * 64 + 64)
    let ist_pos = [typed.u8(48), typed.u8(48)]
    let grs = [new_gr(), new_gr(), new_gr(), new_gr()]

    func reset():
        for i in range(4):
            dec.header[i] = 0
        dec.free_format_bytes = 0
        dec.reserv = 0
        for i in range(len(dec.mdct_overlap)):
            dec.mdct_overlap[i] = 0.0
        for i in range(len(dec.qmf_state)):
            dec.qmf_state[i] = 0.0

    reset()

    # one granule: layer3 decode of nch channels starting at grs[gi]
    func l3_decode(bs, h, o, gi, nch):
        for ch in range(nch):
            let g = grs[gi + ch]
            let limit = bs.pos + g.part_23_length
            decode_scalefactors(h, o, ist_pos[ch], bs, g, scf, ch)
            huffman(grbuf, ch * 576, bs, g, scf, limit)
        if (h[o + 3] & 0x10) != 0:
            intensity_stereo(grbuf, ist_pos[1], grs, gi, h, o)
        elif hdr_is_ms(h, o):
            midside(grbuf, 0, 576)
        for ch in range(nch):
            let g = grs[gi + ch]
            let aa_bands = 31
            let n_long_bands = (2 if g.mixed_block_flag != 0 else 0) << (1 if hdr_my_sr(h, o) == 2 else 0)
            if g.n_short_sfb != 0:
                aa_bands = n_long_bands - 1
                reorder(grbuf, ch * 576 + n_long_bands * 18, syn, g.sfbtab, g.n_long_sfb)
            antialias(grbuf, ch * 576, aa_bands)
            # mdct_overlap is [2][288]
            imdct_gr(grbuf, ch * 576, dec.mdct_overlap, ch * 288, g.block_type, n_long_bands)
            change_sign(grbuf, ch * 576)

    # decode one frame found at m[off..]; pcm: typed.i16 or nil
    # returns {samples, frame_bytes, frame_offset, channels, hz, layer, bitrate_kbps}
    func decode_frame(m, off, n, pcm, po):
        let frame_size = 0
        let i = 0
        if n > 4 and dec.header[0] == 0xff and hdr_compare(dec.header, 0, m, off):
            frame_size = hdr_frame_bytes(m, off, dec.free_format_bytes) + hdr_padding(m, off)
            if frame_size != n and (frame_size + 4 > n or not hdr_compare(m, off, m, off + frame_size)):
                frame_size = 0
        if frame_size == 0:
            reset()
            let r = find_frame(m, off, n, dec.free_format_bytes)
            i = r[0]
            frame_size = r[1]
            dec.free_format_bytes = r[2]
            if frame_size == 0 or i + frame_size > n:
                return {samples: 0, frame_bytes: i}
        let hp = off + i
        for k in range(4):
            dec.header[k] = m[hp + k]
        let channels = 1 if hdr_is_mono(m, hp) else 2
        let layer = 4 - hdr_layer(m, hp)
        let info = {samples: 0, frame_bytes: i + frame_size, frame_offset: i, channels: channels, hz: hdr_hz(m, hp), layer: layer, bitrate_kbps: hdr_bitrate_kbps(m, hp)}
        if pcm == nil:
            info.samples = hdr_frame_samples(m, hp)
            return info
        if layer != 3:
            return info
        let payload = frame_size - 4
        let bs = {buf: m, pos: 0, limit: payload * 8}
        # a bit reader over the frame bytes after the header: copy so that offsets start at 0 (plus guard bytes)
        let fb = typed.u8(payload + 8)
        for k in range(payload):
            fb[k] = m[hp + 4 + k]
        bs.buf = fb
        if hdr_is_crc(m, hp):
            get_bits(bs, 16)
        let mdb = read_side_info(bs, grs, m, hp)
        if mdb < 0 or bs.pos > bs.limit:
            reset()
            return info
        # restore the bit reservoir
        let frame_bytes = (bs.limit - bs.pos) // 8
        let bytes_have = imin(dec.reserv, mdb)
        let rs = imax(0, dec.reserv - mdb)
        for k in range(bytes_have):
            maindata[k] = dec.reserv_buf[rs + k]
        let sp = bs.pos >> 3
        for k in range(frame_bytes):
            maindata[bytes_have + k] = fb[sp + k]
        for k in range(8):
            maindata[bytes_have + frame_bytes + k] = 0
        let ms = {buf: maindata, pos: 0, limit: (bytes_have + frame_bytes) * 8}
        let success = dec.reserv >= mdb
        let ngr = 2 if hdr_mpeg1(m, hp) else 1
        if success:
            for k in range(2):
                for q in range(48):
                    ist_pos[k][q] = 0
            for igr in range(ngr):
                for k in range(len(grbuf)):
                    grbuf[k] = 0.0
                l3_decode(ms, m, hp, igr * channels, channels)
                synth_granule(dec.qmf_state, grbuf, 18, channels, pcm, po + igr * 576 * channels, syn)
        # save the reservoir
        let pos = (ms.pos + 7) // 8
        let remains = ms.limit // 8 - pos
        if remains > MAX_RESERV:
            pos += remains - MAX_RESERV
            remains = MAX_RESERV
        if remains > 0:
            for k in range(remains):
                dec.reserv_buf[k] = maindata[pos + k]
        dec.reserv = imax(remains, 0)
        info.samples = hdr_frame_samples(dec.header, 0) if success else 0
        return info

    return {decode_frame: decode_frame, reset: reset}

func skip_id3v2(d, n):
    if n >= 10 and d[0] == 0x49 and d[1] == 0x44 and d[2] == 0x33 and d[3] < 0xff and d[4] < 0xff and ((d[6] | d[7] | d[8] | d[9]) & 0x80) == 0:
        let sz = (d[6] << 21) | (d[7] << 14) | (d[8] << 7) | d[9]
        let total = sz + 10 + (10 if (d[5] & 0x10) != 0 else 0)
        return imin(total, n)
    return 0

# true if the frame at o holds a Xing / Info / VBRI tag (it carries no audio)
func is_tag_frame(d, o, n):
    let mono = hdr_is_mono(d, o)
    let mpeg1 = hdr_mpeg1(d, o)
    let side = (17 if mono else 32) if mpeg1 else (9 if mono else 17)
    let p = o + 4 + side + (2 if hdr_is_crc(d, o) else 0)
    if p + 4 <= n:
        let a = d[p]
        let b = d[p + 1]
        let c = d[p + 2]
        let e = d[p + 3]
        if (a == 0x58 and b == 0x69 and c == 0x6e and e == 0x67) or (a == 0x49 and b == 0x6e and c == 0x66 and e == 0x6f):
            return true
    let q = o + 4 + 32
    if q + 4 <= n and d[q] == 0x56 and d[q + 1] == 0x42 and d[q + 2] == 0x52 and d[q + 3] == 0x49:
        return true
    return false

export func info(data):
    let d = as_u8(data)
    let n = len(d)
    let pos = skip_id3v2(d, n)
    let dec = Decoder()
    let frames = 0
    let samples = 0
    let first = nil
    while pos < n:
        let r = dec.decode_frame(d, pos, n - pos, nil, 0)
        if r.frame_bytes == 0:
            break
        if r.samples > 0 and r.layer == 3:
            if first == nil:
                first = r
                if is_tag_frame(d, pos + r.frame_offset, n):
                    pos += r.frame_bytes
                    continue
            frames += 1
            samples += r.samples
        pos += r.frame_bytes
    if first == nil:
        fail("sprintmp3: no MPEG audio frames")
    return {sample_rate: first.hz, channels: first.channels, bitrate_kbps: first.bitrate_kbps, layer: first.layer, frames: frames, samples: samples}

export func decode(data):
    let d = as_u8(data)
    let n = len(d)
    let pos = skip_id3v2(d, n)
    let dec = Decoder()
    let chunks = []
    let total = 0
    let hz = 0
    let channels = 0
    let tmp = typed.i16(1152 * 2)
    let seen = false
    while pos < n:
        let r = dec.decode_frame(d, pos, n - pos, tmp, 0)
        if r.frame_bytes == 0:
            break
        if not seen and r.samples > 0 and is_tag_frame(d, pos + r.frame_offset, n):
            seen = true
            dec.reset()
            pos += r.frame_bytes
            continue
        if r.samples > 0:
            seen = true
            if hz == 0:
                hz = r.hz
                channels = r.channels
            if r.hz == hz and r.channels == channels:
                let c = typed.i16(r.samples * channels)
                for k in range(r.samples * channels):
                    c[k] = tmp[k]
                chunks.append(c)
                total += r.samples
        pos += r.frame_bytes
    if hz == 0:
        fail("sprintmp3: no decodable MPEG audio frames")
    let out = typed.i16(total * channels)
    let k = 0
    for c in chunks:
        for j in range(len(c)):
            out[k] = c[j]
            k += 1
    return {sample_rate: hz, channels: channels, frames: total, samples: out}
