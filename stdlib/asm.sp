# asm: an x86 / x86-64 assembler written in Sprint (Intel syntax, a NASM-compatible subset), producing flat binary.
#
#   import asm
#   let r = asm.assemble(source, {bits: 16, org: 0x7c00})
#   r.bytes      # array of ints 0..255
#   r.symbols    # table: label -> address
#   fs.write_bytes("boot.img", r.bytes)
#
# Directives: bits / use16 / use32 / use64, org, db dw dd dq, resb resw resd resq, times, equ, align / alignb, section (ignored),
# global / extern (ignored), default rel|abs, %define / %assign.  Labels may be local (".loop", scoped by the last global label).
# Instructions cover real mode, protected mode and long mode system code: ALU, mov (incl. control / debug / segment registers),
# stack, jumps and calls (short / near / far, sized automatically over several passes), string ops with rep prefixes, shifts,
# in / out, lgdt / lidt / ltr, movzx / movsx, setcc / cmovcc, bt*, xchg / xadd / cmpxchg, cpuid / rdmsr / wrmsr / syscall ...
# Nothing here needs a capability: the result is data. fs.write_bytes writes it to a file, ffi.asm runs it (x86-64 hosts).
import str
import ffi

let MNEM = {}

# ---- registers -----------------------------------------------------------------------------------
let REG = {}
func def_regs(names, cls, bits):
    for i in range(len(names)):
        REG[names[i]] = {name: names[i], cls: cls, num: i, bits: bits, rex: false, high: false}
def_regs(["al", "cl", "dl", "bl", "spl", "bpl", "sil", "dil", "r8b", "r9b", "r10b", "r11b", "r12b", "r13b", "r14b", "r15b"], "gpr", 8)
def_regs(["ax", "cx", "dx", "bx", "sp", "bp", "si", "di", "r8w", "r9w", "r10w", "r11w", "r12w", "r13w", "r14w", "r15w"], "gpr", 16)
def_regs(["eax", "ecx", "edx", "ebx", "esp", "ebp", "esi", "edi", "r8d", "r9d", "r10d", "r11d", "r12d", "r13d", "r14d", "r15d"], "gpr", 32)
def_regs(["rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15"], "gpr", 64)
def_regs(["es", "cs", "ss", "ds", "fs", "gs"], "seg", 16)
def_regs(["xmm0", "xmm1", "xmm2", "xmm3", "xmm4", "xmm5", "xmm6", "xmm7", "xmm8", "xmm9", "xmm10", "xmm11", "xmm12", "xmm13", "xmm14", "xmm15"], "xmm", 128)
def_regs(["cr0", "cr1", "cr2", "cr3", "cr4", "cr5", "cr6", "cr7", "cr8", "cr9", "cr10", "cr11", "cr12", "cr13", "cr14", "cr15"], "cr", 64)
def_regs(["dr0", "dr1", "dr2", "dr3", "dr4", "dr5", "dr6", "dr7"], "dr", 64)
for nm in ["spl", "bpl", "sil", "dil"]:
    REG[nm].rex = true
for i in range(8, 16):
    REG["r" .. to_string(i) .. "b"].rex = false
let HIGH8 = ["ah", "ch", "dh", "bh"]
for k in range(4):
    REG[HIGH8[k]] = {name: HIGH8[k], cls: "gpr", num: 4 + k, bits: 8, rex: false, high: true}
REG["r8l"] = REG["r8b"]
REG["r9l"] = REG["r9b"]
REG["r10l"] = REG["r10b"]
REG["r11l"] = REG["r11b"]
REG["r12l"] = REG["r12b"]
REG["r13l"] = REG["r13b"]
REG["r14l"] = REG["r14b"]
REG["r15l"] = REG["r15b"]
const SEGNUM = {es: 0, cs: 1, ss: 2, ds: 3, fs: 4, gs: 5}
const SEGPFX = {es: 0x26, cs: 0x2e, ss: 0x36, ds: 0x3e, fs: 0x64, gs: 0x65}
const SIZEKW = {byte: 8, word: 16, dword: 32, qword: 64, tword: 80, oword: 128}

const ALU = {add: 0, or: 1, adc: 2, sbb: 3, and: 4, sub: 5, xor: 6, cmp: 7}
const SHIFT = {rol: 0, ror: 1, rcl: 2, rcr: 3, shl: 4, sal: 4, shr: 5, sar: 7}
const CC = {o: 0, no: 1, b: 2, c: 2, nae: 2, nb: 3, nc: 3, ae: 3, e: 4, z: 4, ne: 5, nz: 5, be: 6, na: 6, nbe: 7, a: 7,
            s: 8, ns: 9, p: 10, pe: 10, np: 11, po: 11, l: 12, nge: 12, nl: 13, ge: 13, le: 14, ng: 14, nle: 15, g: 15}
const SIMPLE = {nop: [0x90], hlt: [0xf4], cli: [0xfa], sti: [0xfb], cld: [0xfc], std: [0xfd], clc: [0xf8], stc: [0xf9], cmc: [0xf5],
                wait: [0x9b], fwait: [0x9b], lahf: [0x9f], sahf: [0x9e], leave: [0xc9], int3: [0xcc], into: [0xce], int1: [0xf1], icebp: [0xf1],
                cpuid: [0x0f, 0xa2], rdtsc: [0x0f, 0x31], rdmsr: [0x0f, 0x32], wrmsr: [0x0f, 0x30], rdpmc: [0x0f, 0x33], syscall: [0x0f, 0x05],
                sysret: [0x0f, 0x07], sysenter: [0x0f, 0x34], sysexit: [0x0f, 0x35], ud2: [0x0f, 0x0b], wbinvd: [0x0f, 0x09],
                invd: [0x0f, 0x08], rsm: [0x0f, 0xaa], clts: [0x0f, 0x06], pause: [0xf3, 0x90], xlat: [0xd7], xlatb: [0xd7],
                lfence: [0x0f, 0xae, 0xe8], mfence: [0x0f, 0xae, 0xf0], sfence: [0x0f, 0xae, 0xf8], swapgs: [0x0f, 0x01, 0xf8],
                rdtscp: [0x0f, 0x01, 0xf9], monitor: [0x0f, 0x01, 0xc8], mwait: [0x0f, 0x01, 0xc9], xgetbv: [0x0f, 0x01, 0xd0],
                emms: [0x0f, 0x77], ret: [0xc3], retn: [0xc3], retf: [0xcb], retfq: [0x48, 0xcb], iret: [0xcf], iretq: [0x48, 0xcf],
                sysretq: [0x48, 0x0f, 0x07]}
# size-dependent no-operand instructions: name -> [opcode, size-bits (0: none)]
const SIZED = {pushf: [0x9c, 0], pushfw: [0x9c, 16], pushfd: [0x9c, 32], pushfq: [0x9c, 0], popf: [0x9d, 0], popfw: [0x9d, 16], popfd: [0x9d, 32], popfq: [0x9d, 0],
               pusha: [0x60, 0], pushaw: [0x60, 16], pushad: [0x60, 32], popa: [0x61, 0], popaw: [0x61, 16], popad: [0x61, 32],
               iretw: [0xcf, 16], iretd: [0xcf, 32],
               cbw: [0x98, 16], cwde: [0x98, 32], cdqe: [0x98, 64], cwd: [0x99, 16], cdq: [0x99, 32], cqo: [0x99, 64],
               movsw: [0xa5, 16], movsd: [0xa5, 32], movsq: [0xa5, 64], cmpsw: [0xa7, 16], cmpsd: [0xa7, 32], cmpsq: [0xa7, 64],
               stosw: [0xab, 16], stosd: [0xab, 32], stosq: [0xab, 64], lodsw: [0xad, 16], lodsd: [0xad, 32], lodsq: [0xad, 64],
               scasw: [0xaf, 16], scasd: [0xaf, 32], scasq: [0xaf, 64], insw: [0x6d, 16], insd: [0x6d, 32], outsw: [0x6f, 16], outsd: [0x6f, 32],
               movsb: [0xa4, 8], cmpsb: [0xa6, 8], stosb: [0xaa, 8], lodsb: [0xac, 8], scasb: [0xae, 8], insb: [0x6c, 8], outsb: [0x6e, 8]}
const DIRECTIVES = ["bits", "use16", "use32", "use64", "org", "db", "dw", "dd", "dq", "resb", "resw", "resd", "resq", "times", "equ",
                    "align", "alignb", "section", "segment", "global", "extern", "default", "cpu", "absolute", "incbin"]
const PREFIXES = {rep: 0xf3, repe: 0xf3, repz: 0xf3, repne: 0xf2, repnz: 0xf2, lock: 0xf0}

func fail(msg, line = 0):
    if line > 0:
        throw error("AsmError", "line " .. to_string(line) .. ": " .. msg)
    throw error("AsmError", msg)

# ---- tokens --------------------------------------------------------------------------------------
func is_digit(ch):
    return ch >= 48 and ch <= 57

func is_idstart(ch):
    return (ch >= 97 and ch <= 122) or (ch >= 65 and ch <= 90) or ch == 95 or ch == 46 or ch == 64 or ch == 63

func is_idchar(ch):
    return is_idstart(ch) or is_digit(ch) or ch == 36 or ch == 35 or ch == 126

func digit_val(ch):
    if ch >= 48 and ch <= 57:
        return ch - 48
    if ch >= 97 and ch <= 102:
        return ch - 87
    if ch >= 65 and ch <= 70:
        return ch - 55
    return 99

# a number literal: 123, 0x1F, 1Fh, $1F, 0b101, 101b, 0o17, 17o, 17q, 1_000
func parse_num(text):
    let s = text.lower().replace("_", "")
    let base = 10
    if s.starts_with("0x"):
        base = 16
        s = s.slice(2)
    elif s.starts_with("0b") and len(s) > 2 and not s.contains("h"):
        base = 2
        s = s.slice(2)
    elif s.starts_with("0o") or s.starts_with("0q"):
        base = 8
        s = s.slice(2)
    elif s.starts_with("0d"):
        s = s.slice(2)
    elif s.ends_with("h"):
        base = 16
        s = s.slice(0, len(s) - 1)
    elif s.ends_with("b") and len(s) > 1:
        base = 2
        s = s.slice(0, len(s) - 1)
    elif s.ends_with("o") or s.ends_with("q"):
        base = 8
        s = s.slice(0, len(s) - 1)
    elif s.ends_with("d"):
        s = s.slice(0, len(s) - 1)
    if len(s) == 0:
        return nil
    let v = 0
    for i in range(len(s)):
        let d = digit_val(s[i])
        if d >= base:
            return nil
        if base == 16:
            v = (v << 4) | d          # literals above 2^63 wrap to the 64-bit two's complement value
        elif base == 2:
            v = (v << 1) | d
        elif base == 8:
            v = (v << 3) | d
        else:
            v = v * base + d
    return v

# [kind, value] tokens: "n" number, "i" identifier, "s" string, "o" operator
func tokenize(line, ln):
    let toks = []
    let i = 0
    let n = len(line)
    while i < n:
        let ch = line[i]
        if ch == 32 or ch == 9 or ch == 13:
            i += 1
        elif ch == 59:
            break
        elif is_digit(ch):
            let j = i
            while j < n and (is_idchar(line[j]) or line[j] == 46):
                j += 1
            let v = parse_num(line.slice(i, j))
            if v == nil:
                fail("bad number '" .. line.slice(i, j) .. "'", ln)
            toks.append(["n", v])
            i = j
        elif ch == 36 and i + 1 < n and line[i + 1] == 36:
            toks.append(["i", "$$"])
            i += 2
        elif ch == 36 and (i + 1 >= n or not is_idchar(line[i + 1])):
            toks.append(["i", "$"])
            i += 1
        elif ch == 36 and i + 1 < n and digit_val(line[i + 1]) < 16:
            let j = i + 1
            while j < n and is_idchar(line[j]):
                j += 1
            let v = parse_num("0x" .. line.slice(i + 1, j))
            toks.append(["n", v])
            i = j
        elif is_idstart(ch) or ch == 36:
            let j = i + 1
            while j < n and is_idchar(line[j]):
                j += 1
            toks.append(["i", line.slice(i, j).lower() if REG_OR_KW(line.slice(i, j)) else line.slice(i, j)])
            i = j
        elif ch == 39 or ch == 34 or ch == 96:
            let j = i + 1
            while j < n and line[j] != ch:
                j += 1
            if j >= n:
                fail("unterminated string", ln)
            toks.append(["s", line.slice(i + 1, j)])
            i = j + 1
        elif (ch == 60 or ch == 62) and i + 1 < n and line[i + 1] == ch:
            toks.append(["o", line.slice(i, i + 2)])
            i += 2
        elif ch == 47 and i + 1 < n and line[i + 1] == 47:
            toks.append(["o", "//"])
            i += 2
        elif "+-*/%&|^~()[],:".contains(line.slice(i, i + 1)):
            toks.append(["o", line.slice(i, i + 1)])
            i += 1
        else:
            fail("unexpected character '" .. line.slice(i, i + 1) .. "'", ln)
    return toks

# mnemonics, registers and keywords are case-insensitive; labels keep their case
func REG_OR_KW(w):
    let l = w.lower()
    if has(REG, l) or has(SIZEKW, l) or has(SIMPLE, l) or has(SIZED, l) or has(ALU, l) or has(SHIFT, l) or has(PREFIXES, l):
        return true
    if DIRECTIVES.contains(l) or has(MNEM, l) or has_jcc(l):
        return true
    return ["rip", "short", "near", "far", "ptr", "rel", "abs", "strict", "nosplit"].contains(l)

func has_jcc(l):
    if l.starts_with("j") and has(CC, l.slice(1)):
        return true
    if l.starts_with("set") and has(CC, l.slice(3)):
        return true
    if l.starts_with("cmov") and has(CC, l.slice(4)):
        return true
    return false

# ---- expressions -----------------------------------------------------------------------------------
# a value is {v: int, n: label count (0: a plain constant), u: depends on an undefined symbol}
func mkv(v, n = 0):
    return {v: v, n: n, u: false}

func ex_peek(x):
    return x.t[x.p] if x.p < len(x.t) else nil

func ex_op(x, o):
    let t = ex_peek(x)
    return t != nil and t[0] == "o" and t[1] == o

func ex_eof(x):
    return x.p >= len(x.t)

func sym_name(c, name):
    if name.starts_with(".") and not name.starts_with(".."):
        return c.last .. name
    return name

func ex_prim(x):
    let c = x.c
    let t = ex_peek(x)
    if t == nil:
        fail("expression expected", c.line)
    x.p += 1
    if t[0] == "n":
        return mkv(t[1])
    if t[0] == "s":
        let v = 0
        let s = t[1]
        for i in range(len(s)):
            if i < 8:
                v = v | (s[i] << (8 * i))
        return mkv(v)
    if t[0] == "o":
        if t[1] == "(":
            let r = ex_or(x)
            if not ex_op(x, ")"):
                fail("')' expected", c.line)
            x.p += 1
            return r
        fail("unexpected '" .. t[1] .. "' in expression", c.line)
    let name = t[1]
    if name == "$":
        return mkv(c.here, 1)
    if name == "$$":
        return mkv(c.org0, 1)
    if has(REG, name):
        fail("register '" .. name .. "' in an expression", c.line)
    let sn = sym_name(c, name)
    if has(c.syms, sn):
        return mkv(c.syms[sn], c.cn[sn] if has(c.cn, sn) else 1)
    if has(c.prev, sn):
        return mkv(c.prev[sn], c.cn[sn] if has(c.cn, sn) else 1)
    c.undef.append(sn)
    return {v: 0, n: 1, u: true}

func ex_unary(x):
    if ex_op(x, "-"):
        x.p += 1
        let r = ex_unary(x)
        return {v: -r.v, n: -r.n, u: r.u}
    if ex_op(x, "+"):
        x.p += 1
        return ex_unary(x)
    if ex_op(x, "~"):
        x.p += 1
        let r = ex_unary(x)
        return {v: ~r.v, n: r.n, u: r.u}
    return ex_prim(x)

func ex_mul(x):
    let a = ex_unary(x)
    while true:
        let t = ex_peek(x)
        if t == nil or t[0] != "o" or not ["*", "/", "//", "%"].contains(t[1]):
            break
        x.p += 1
        let b = ex_unary(x)
        let u = a.u or b.u
        let v = 0
        if not u:
            if t[1] == "*":
                v = a.v * b.v
            else:
                if b.v == 0:
                    fail("division by zero", x.c.line)
                if t[1] == "%":
                    v = a.v % b.v
                else:
                    v = a.v // b.v
        a = {v: v, n: a.n + b.n, u: u}
    return a

func ex_add(x):
    let a = ex_mul(x)
    while true:
        if ex_op(x, "+"):
            x.p += 1
            let b = ex_mul(x)
            a = {v: a.v + b.v, n: a.n + b.n, u: a.u or b.u}
        elif ex_op(x, "-"):
            x.p += 1
            let b = ex_mul(x)
            a = {v: a.v - b.v, n: a.n - b.n, u: a.u or b.u}
        else:
            break
    return a

func ex_shift(x):
    let a = ex_add(x)
    while true:
        let t = ex_peek(x)
        if t == nil or t[0] != "o" or not ["<<", ">>"].contains(t[1]):
            break
        x.p += 1
        let b = ex_add(x)
        let v = 0
        if not (a.u or b.u):
            v = (a.v << b.v) if t[1] == "<<" else (a.v >> b.v)
        a = {v: v, n: a.n + b.n, u: a.u or b.u}
    return a

func ex_and(x):
    let a = ex_shift(x)
    while ex_op(x, "&"):
        x.p += 1
        let b = ex_shift(x)
        a = {v: a.v & b.v, n: a.n + b.n, u: a.u or b.u}
    return a

func ex_xor(x):
    let a = ex_and(x)
    while ex_op(x, "^"):
        x.p += 1
        let b = ex_and(x)
        a = {v: a.v ^ b.v, n: a.n + b.n, u: a.u or b.u}
    return a

func ex_or(x):
    let a = ex_xor(x)
    while ex_op(x, "|"):
        x.p += 1
        let b = ex_xor(x)
        a = {v: a.v | b.v, n: a.n + b.n, u: a.u or b.u}
    return a

func eval_toks(c, toks):
    let x = {c: c, t: toks, p: 0}
    let r = ex_or(x)
    if not ex_eof(x):
        fail("unexpected '" .. to_string(x.t[x.p][1]) .. "' after the expression", c.line)
    return r

# ---- operands ----------------------------------------------------------------------------------------
func split_commas(toks):
    let out = []
    let cur = []
    let depth = 0
    for t in toks:
        if t[0] == "o" and (t[1] == "(" or t[1] == "["):
            depth += 1
        elif t[0] == "o" and (t[1] == ")" or t[1] == "]"):
            depth -= 1
        if depth == 0 and t[0] == "o" and t[1] == ",":
            out.append(cur)
            cur = []
        else:
            cur.append(t)
    if len(cur) > 0 or len(out) > 0:
        out.append(cur)
    return out

func is_reg_tok(t):
    return t[0] == "i" and has(REG, t[1])

# split a token list at depth-0 '+' / '-' into signed terms
func split_terms(toks):
    let terms = []
    let cur = []
    let sign = 1
    let depth = 0
    for t in toks:
        if t[0] == "o" and t[1] == "(":
            depth += 1
        elif t[0] == "o" and t[1] == ")":
            depth -= 1
        if depth == 0 and t[0] == "o" and (t[1] == "+" or t[1] == "-") and len(cur) > 0:
            terms.append([sign, cur])
            cur = []
            sign = 1 if t[1] == "+" else -1
        elif depth == 0 and t[0] == "o" and t[1] == "-" and len(cur) == 0:
            sign = -sign
        elif depth == 0 and t[0] == "o" and t[1] == "+" and len(cur) == 0:
            sign = sign
        else:
            cur.append(t)
    if len(cur) > 0:
        terms.append([sign, cur])
    return terms

func parse_mem(c, o, toks):
    o.k = "mem"
    let i = 0
    let relkw = false
    let abskw = false
    while i < len(toks):
        let t = toks[i]
        if t[0] == "i" and t[1] == "rel":
            relkw = true
            i += 1
        elif t[0] == "i" and t[1] == "abs":
            abskw = true
            i += 1
        elif t[0] == "i" and has(SEGNUM, t[1]) and i + 1 < len(toks) and toks[i + 1][0] == "o" and toks[i + 1][1] == ":":
            o.seg = t[1]
            i += 2
        else:
            break
    let regs = []
    let disp = 0
    let dn = 0
    let du = false
    let rip = false
    for term in split_terms(toks.slice(i)):
        let sign = term[0]
        let tt = term[1]
        let ridx = -1
        for j in range(len(tt)):
            if tt[j][0] == "i" and (has(REG, tt[j][1]) or tt[j][1] == "rip"):
                ridx = j
                break
        if ridx < 0:
            let v = eval_toks(c, tt)
            disp += sign * v.v
            dn += v.n
            du = du or v.u
        else:
            let nm = tt[ridx][1]
            let coef = 1
            if len(tt) > 1:
                if ridx == 0 and tt[1][0] == "o" and tt[1][1] == "*":
                    coef = eval_toks(c, tt.slice(2)).v
                elif ridx == len(tt) - 1 and tt[ridx - 1][0] == "o" and tt[ridx - 1][1] == "*":
                    coef = eval_toks(c, tt.slice(0, ridx - 1)).v
                else:
                    fail("invalid memory operand", c.line)
            if sign < 0:
                fail("a register cannot be subtracted in an address", c.line)
            if nm == "rip":
                rip = true
            else:
                let r = REG[nm]
                if r.cls != "gpr" or r.bits == 8:
                    fail("invalid register '" .. nm .. "' in an address", c.line)
                if c.bits != 64 and (r.bits == 64 or r.num >= 8):
                    fail("'" .. nm .. "' needs 64-bit mode", c.line)
                if c.bits == 64 and r.bits == 16:
                    fail("16-bit addressing is not available in 64-bit mode", c.line)
                regs.append([r, coef])
    o.disp = disp
    o.dn = dn
    o.du = du
    o.base = nil
    o.index = nil
    o.scale = 1
    o.abits = nil
    o.rip = false
    o.ripabs = false
    if rip:
        if len(regs) > 0:
            fail("rip cannot be combined with other registers", c.line)
        if c.bits != 64:
            fail("rip-relative addressing needs 64-bit mode", c.line)
        o.rip = true
        o.abits = 64
        return o
    if len(regs) == 0:
        if c.bits == 64 and ((relkw or (c.default_rel and not abskw))):
            o.rip = true
            o.ripabs = true
            o.abits = 64
        return o
    let ab = regs[0][0].bits
    for r in regs:
        if r[0].bits != ab:
            fail("mixed register sizes in an address", c.line)
    o.abits = ab
    if len(regs) > 2:
        fail("too many registers in an address", c.line)
    if len(regs) == 2:
        let r0 = regs[0]
        let r1 = regs[1]
        if r0[1] != 1 and r1[1] == 1:
            let t = r0
            r0 = r1
            r1 = t
        if r0[1] != 1:
            fail("invalid scale in an address", c.line)
        o.base = r0[0]
        o.index = r1[0]
        o.scale = r1[1]
        if ab == 16:
            if o.scale != 1:
                fail("16-bit addresses cannot be scaled", c.line)
            # normalise to base = bx/bp, index = si/di
            if o.base.name == "si" or o.base.name == "di":
                let t = o.base
                o.base = o.index
                o.index = t
        elif o.scale == 1 and o.index.num == 4:
            let t = o.base
            o.base = o.index
            o.index = t
    else:
        if regs[0][1] == 1:
            o.base = regs[0][0]
        else:
            o.index = regs[0][0]
            o.scale = regs[0][1]
            if ab == 16:
                fail("16-bit addresses cannot be scaled", c.line)
    if o.base == nil and o.index != nil and o.scale == 2 and ab != 16:
        o.base = o.index       # NASM: [eax*2] is [eax+eax]
        o.scale = 1
    if not [1, 2, 4, 8].contains(o.scale):
        fail("invalid scale " .. to_string(o.scale), c.line)
    if o.index != nil and o.index.num == 4 and ab != 16:
        fail("esp / rsp cannot be an index register", c.line)
    return o

func parse_operand(c, toks):
    let o = {k: nil, size: 0, near: false, short: false, far: false, seg: nil}
    let i = 0
    while i < len(toks) and toks[i][0] == "i":
        let w = toks[i][1]
        if has(SIZEKW, w):
            o.size = SIZEKW[w]
        elif w == "short":
            o.short = true
        elif w == "near":
            o.near = true
        elif w == "far":
            o.far = true
        elif w == "strict" or w == "ptr" or w == "nosplit":
            pass
        else:
            break
        i += 1
    let rest = toks.slice(i)
    if len(rest) == 0:
        fail("operand expected", c.line)
    if len(rest) >= 3 and rest[0][0] == "i" and has(SEGNUM, rest[0][1]) and rest[1][0] == "o" and rest[1][1] == ":" and rest[2][0] == "o" and rest[2][1] == "[":
        o.seg = rest[0][1]
        rest = rest.slice(2)
    if rest[0][0] == "o" and rest[0][1] == "[":
        let last = rest[len(rest) - 1]
        if not (last[0] == "o" and last[1] == "]"):
            fail("']' expected", c.line)
        return parse_mem(c, o, rest.slice(1, len(rest) - 1))
    if len(rest) == 1 and is_reg_tok(rest[0]):
        o.k = "reg"
        o.reg = REG[rest[0][1]]
        if c.bits != 64 and ((o.reg.cls == "gpr" and (o.reg.bits == 64 or o.reg.rex)) or o.reg.num >= 8):
            fail("'" .. o.reg.name .. "' needs 64-bit mode", c.line)
        return o
    # far pointer seg:offset
    let depth = 0
    for j in range(len(rest)):
        let t = rest[j]
        if t[0] == "o" and (t[1] == "(" or t[1] == "["):
            depth += 1
        elif t[0] == "o" and (t[1] == ")" or t[1] == "]"):
            depth -= 1
        elif depth == 0 and t[0] == "o" and t[1] == ":":
            o.k = "far"
            o.seg_v = eval_toks(c, rest.slice(0, j))
            o.off_v = eval_toks(c, rest.slice(j + 1))
            return o
    let v = eval_toks(c, rest)
    o.k = "imm"
    o.v = v.v
    o.n = v.n
    o.u = v.u
    return o

# ---- encoding helpers -------------------------------------------------------------------------------
func cat(...parts):
    let out = []
    for p in parts:
        for b in p:
            out.append(b)
    return out

func le(v, n):
    let out = []
    for i in range(n):
        out.append((v >> (8 * i)) & 255)
    return out

func fits8(v):
    return v >= -128 and v <= 127

# a constant that fits a sign-extended imm8 once wrapped to the operand size (0xFFFF in a 16-bit operation is -1)
func fits8s(v, size):
    if size < 64:
        let w = v & ((1 << size) - 1)
        if w >= (1 << (size - 1)):
            w -= 1 << size
        return fits8(w)
    return fits8(v)

# an immediate that can be shrunk: a known constant (no labels)
func is_const(o):
    return o.k == "imm" and o.n == 0 and not o.u

const SCALEBITS = {1: 0, 2: 1, 4: 2, 8: 3}
const RM16 = {"bx+si": 0, "bx+di": 1, "bp+si": 2, "bp+di": 3, "si": 4, "di": 5, "bp": 6, "bx": 7}

# ModRM (+ SIB + displacement) for operand `rm` with register field `regf`
func modrm(c, regf, rm):
    let r = {b: [], x: 0, bb: 0, ad: 0, rip: -1, ripabs: false, target: 0}
    let rf = (regf & 7) << 3
    if rm.k == "reg":
        r.b.append(0xc0 | rf | (rm.reg.num & 7))
        r.bb = rm.reg.num >> 3
        return r
    let ab = rm.abits if rm.abits != nil else c.bits
    r.ad = ab
    let d = rm.disp
    let known = rm.dn == 0 and not rm.du
    if ab == 16:
        if c.bits == 64:
            fail("16-bit addressing is not available in 64-bit mode", c.line)
        if rm.base == nil and rm.index == nil:
            r.b = cat([0x06 | rf], le(d, 2))
            return r
        let key = rm.base.name if rm.index == nil else rm.base.name .. "+" .. rm.index.name
        if rm.base == nil:
            key = rm.index.name
        if not has(RM16, key):
            fail("invalid 16-bit address '" .. key .. "'", c.line)
        let code = RM16[key]
        if known and d == 0 and code != 6:
            r.b = [rf | code]
        elif known and fits8(d):
            r.b = cat([0x40 | rf | code], le(d, 1))
        else:
            r.b = cat([0x80 | rf | code], le(d, 2))
        return r
    if rm.rip:
        r.b = [0x05 | rf, 0, 0, 0, 0]
        r.rip = 1
        r.ripabs = rm.ripabs
        r.target = d
        return r
    if rm.base == nil and rm.index == nil:
        if ab == 64:
            r.b = cat([0x04 | rf, 0x25], le(d, 4))
        else:
            r.b = cat([0x05 | rf], le(d, 4))
        return r
    let idx = rm.index
    let base = rm.base
    if idx != nil:
        r.x = idx.num >> 3
    if base == nil:
        r.b = cat([0x04 | rf, (SCALEBITS[rm.scale] << 6) | ((idx.num & 7) << 3) | 5], le(d, 4))
        return r
    r.bb = base.num >> 3
    let bn = base.num & 7
    let mod = 2
    if known and d == 0 and bn != 5:
        mod = 0
    elif known and fits8(d):
        mod = 1
    let disp = [] if mod == 0 else (le(d, 1) if mod == 1 else le(d, 4))
    if idx != nil or bn == 4:
        let ib = 4 if idx == nil else (idx.num & 7)
        let sc = 0 if idx == nil else SCALEBITS[rm.scale]
        r.b = cat([(mod << 6) | rf | 4, (sc << 6) | (ib << 3) | bn], disp)
    else:
        r.b = cat([(mod << 6) | rf | bn], disp)
    return r

# Assembles one instruction from a spec:
#   opsz: operand size in bits (8 / 16 / 32 / 64) for the 0x66 prefix and REX.W; p66: force / suppress 0x66
#   opc: opcode bytes; regf: ModRM.reg (register number 0..15 or an opcode extension); rm: operand in ModRM.rm (or nil)
#   imm: immediate bytes appended at the end; bregs: register operands to check for the byte-register / REX rules
func build(c, sp):
    let m = nil
    let regf = sp.regf if sp.regf != nil else 0
    if sp.rm != nil:
        m = modrm(c, regf, sp.rm)
    let opsz = sp.opsz if sp.opsz != nil else 0
    let p66 = false
    if sp.p66 != nil:
        p66 = sp.p66
    else:
        p66 = (opsz == 16 and c.bits != 16) or (opsz == 32 and c.bits == 16)
    let rex = 0
    let need = false
    if opsz == 64 and not sp.norexw:
        rex = rex | 8
    if ((regf >> 3) & 1) == 1:
        rex = rex | 4
    if sp.opreg != nil and sp.opreg >= 8:
        rex = rex | 1
    if m != nil:
        if m.x == 1:
            rex = rex | 2
        if m.bb == 1:
            rex = rex | 1
    let high = false
    if sp.bregs != nil:
        for r in sp.bregs:
            if r.bits == 8 and r.cls == "gpr":
                if r.rex or r.num >= 8:
                    need = true
                if r.high:
                    high = true
    if rex != 0 or need:
        if c.bits != 64:
            fail("64-bit registers / operands need 64-bit mode", c.line)
        if high:
            fail("ah / ch / dh / bh cannot be used with a REX prefix", c.line)
        rex = rex | 0x40
    let out = []
    let sg = sp.seg
    if sg == nil and sp.rm != nil and sp.rm.k == "mem":
        sg = sp.rm.seg
    if sg != nil:
        out.append(SEGPFX[sg])
    if p66:
        out.append(0x66)
    if m != nil and m.ad != 0 and m.ad != c.bits:
        out.append(0x67)
    if sp.extra != nil:
        out.append(sp.extra)
    if rex != 0:
        out.append(rex)
    for k in range(len(sp.opc)):
        out.append(sp.opc[k] + (sp.opreg & 7 if sp.opreg != nil and k == len(sp.opc) - 1 else 0))
    let mpos = len(out)
    if m != nil:
        for b in m.b:
            out.append(b)
    let imm = sp.imm if sp.imm != nil else []
    for b in imm:
        out.append(b)
    if m != nil and m.rip >= 0:
        let end = c.here + len(out)
        let rel = m.target - end if m.ripabs else m.target
        if m.ripabs:
            rel = m.target - end
        let at = mpos + 1
        for k in range(4):
            out[at + k] = (rel >> (8 * k)) & 255
    return out

# ---- instructions -------------------------------------------------------------------------------------

func is_gpr(o):
    return o.k == "reg" and o.reg.cls == "gpr"

func is_rm(o):
    return o.k == "mem" or is_gpr(o)

func need_ops(c, mn, o, lo, hi = nil):
    let hi2 = lo if hi == nil else hi
    if len(o) < lo or len(o) > hi2:
        fail("'" .. mn .. "' takes " .. to_string(lo) .. (("-" .. to_string(hi2)) if hi2 != lo else "") .. " operand(s), got " .. to_string(len(o)), c.line)

func mode_osz(c):
    return 16 if c.bits == 16 else 32

# operand size of a pair: from a register, else from an explicit size on the memory operand / immediate
func pick_size(c, a, b):
    let s = 0
    for o in [a, b]:
        if o != nil and is_gpr(o):
            if s != 0 and s != o.reg.bits:
                fail("mismatch in operand sizes", c.line)
            s = o.reg.bits
    if s == 0:
        for o in [a, b]:
            if o != nil and o.k != "reg" and o.size > 0:
                s = o.size
    elif a != nil and b != nil:
        for o in [a, b]:
            if o.k == "mem" and o.size > 0 and o.size != s:
                fail("mismatch in operand sizes", c.line)
    return s

func imm_bytes(c, o, size):
    let n = 4 if size == 64 else size // 8
    return le(o.v, n)

func bregs_of(ops):
    let rs = []
    for o in ops:
        if o != nil and o.k == "reg":
            rs.append(o.reg)
    return rs

func spec(c, opc, regf, rm, opsz, imm, ops):
    return build(c, {opc: opc, regf: regf, rm: rm, opsz: opsz, imm: imm, bregs: bregs_of(ops)})

# the ALU group: add or adc sbb and sub xor cmp
func h_alu(c, n, o):
    need_ops(c, "alu", o, 2)
    let a = o[0]
    let b = o[1]
    if b.k == "imm":
        if not is_rm(a):
            fail("invalid operands", c.line)
        let size = pick_size(c, a, nil)
        if size == 0:
            fail("operation size not specified", c.line)
        if size == 8:
            if is_gpr(a) and a.reg.num == 0:
                return spec(c, [n * 8 + 4], 0, nil, 8, le(b.v, 1), [a])
            return spec(c, [0x80], n, a, 8, le(b.v, 1), [a])
        if is_const(b) and fits8s(b.v, size):
            return spec(c, [0x83], n, a, size, le(b.v, 1), [a])
        if is_gpr(a) and a.reg.num == 0:
            return spec(c, [n * 8 + 5], 0, nil, size, imm_bytes(c, b, size), [a])
        return spec(c, [0x81], n, a, size, imm_bytes(c, b, size), [a])
    let size = pick_size(c, a, b)
    if size == 0:
        fail("operation size not specified", c.line)
    let w = 0 if size == 8 else 1
    if is_gpr(a) and is_gpr(b):
        return spec(c, [n * 8 + w], b.reg.num, a, size, [], [a, b])
    if a.k == "mem" and is_gpr(b):
        return spec(c, [n * 8 + w], b.reg.num, a, size, [], [b])
    if is_gpr(a) and b.k == "mem":
        return spec(c, [n * 8 + 2 + w], a.reg.num, b, size, [], [a])
    fail("invalid operands", c.line)

func h_mov(c, o):
    need_ops(c, "mov", o, 2)
    let a = o[0]
    let b = o[1]
    if a.k == "reg" and (a.reg.cls == "cr" or a.reg.cls == "dr") and is_gpr(b):
        return build(c, {opc: [0x0f, 0x22 if a.reg.cls == "cr" else 0x23], regf: a.reg.num, rm: b, opsz: 0})
    if b.k == "reg" and (b.reg.cls == "cr" or b.reg.cls == "dr") and is_gpr(a):
        return build(c, {opc: [0x0f, 0x20 if b.reg.cls == "cr" else 0x21], regf: b.reg.num, rm: a, opsz: 0})
    if a.k == "reg" and a.reg.cls == "seg":
        if not is_rm(b):
            fail("invalid operands", c.line)
        return build(c, {opc: [0x8e], regf: a.reg.num, rm: b, opsz: 0})
    if b.k == "reg" and b.reg.cls == "seg":
        if not is_rm(a):
            fail("invalid operands", c.line)
        let sz = a.reg.bits if a.k == "reg" else 0
        return build(c, {opc: [0x8c], regf: b.reg.num, rm: a, opsz: sz})
    if is_gpr(a):
        let size = a.reg.bits
        if is_gpr(b):
            if b.reg.bits != size:
                fail("mismatch in operand sizes", c.line)
            return spec(c, [0x88 if size == 8 else 0x89], b.reg.num, a, size, [], [a, b])
        if b.k == "mem":
            if b.size > 0 and b.size != size:
                fail("mismatch in operand sizes", c.line)
            if a.reg.num == 0 and b.base == nil and b.index == nil and not b.rip and c.bits != 64:
                return build(c, {opc: [0xa0 if size == 8 else 0xa1], opsz: size, imm: le(b.disp, c.bits // 8), seg: b.seg, bregs: [a.reg]})
            return spec(c, [0x8a if size == 8 else 0x8b], a.reg.num, b, size, [], [a])
        if b.k == "imm":
            if size == 8:
                return build(c, {opc: [0xb0], opreg: a.reg.num, opsz: 8, imm: le(b.v, 1), bregs: [a.reg]})
            if size == 64:
                if is_const(b) and b.v >= 0 and b.v < 4294967296:
                    return build(c, {opc: [0xb8], opreg: a.reg.num, opsz: 32, imm: le(b.v, 4)})
                if is_const(b) and b.v < 0 and b.v >= -2147483648:
                    return build(c, {opc: [0xc7], regf: 0, rm: a, opsz: 64, imm: le(b.v, 4)})
                return build(c, {opc: [0xb8], opreg: a.reg.num, opsz: 64, imm: le(b.v, 8)})
            return build(c, {opc: [0xb8], opreg: a.reg.num, opsz: size, imm: imm_bytes(c, b, size)})
        fail("invalid operands", c.line)
    if a.k == "mem":
        if is_gpr(b):
            let size = b.reg.bits
            if a.size > 0 and a.size != size:
                fail("mismatch in operand sizes", c.line)
            if b.reg.num == 0 and a.base == nil and a.index == nil and not a.rip and c.bits != 64:
                return build(c, {opc: [0xa2 if size == 8 else 0xa3], opsz: size, imm: le(a.disp, c.bits // 8), seg: a.seg, bregs: [b.reg]})
            return spec(c, [0x88 if size == 8 else 0x89], b.reg.num, a, size, [], [b])
        if b.k == "imm":
            let size = a.size
            if size == 0:
                fail("operation size not specified", c.line)
            if size == 8:
                return spec(c, [0xc6], 0, a, 8, le(b.v, 1), [])
            return spec(c, [0xc7], 0, a, size, imm_bytes(c, b, size), [])
    fail("invalid operands for mov", c.line)

func h_xchg(c, o):
    need_ops(c, "xchg", o, 2)
    let a = o[0]
    let b = o[1]
    if is_gpr(a) and is_gpr(b):
        let size = a.reg.bits
        if b.reg.bits != size:
            fail("mismatch in operand sizes", c.line)
        if size != 8 and (a.reg.num == 0 or b.reg.num == 0) and not (a.reg.num == 0 and b.reg.num == 0 and size == 32 and c.bits == 64):
            let r = b if a.reg.num == 0 else a
            return build(c, {opc: [0x90], opreg: r.reg.num, opsz: size})
        return spec(c, [0x86 if size == 8 else 0x87], a.reg.num, b, size, [], [a, b])
    if a.k == "mem" and is_gpr(b):
        return spec(c, [0x86 if b.reg.bits == 8 else 0x87], b.reg.num, a, b.reg.bits, [], [b])
    if is_gpr(a) and b.k == "mem":
        return spec(c, [0x86 if a.reg.bits == 8 else 0x87], a.reg.num, b, a.reg.bits, [], [a])
    fail("invalid operands for xchg", c.line)

func h_lea(c, o):
    need_ops(c, "lea", o, 2)
    if not (is_gpr(o[0]) and o[1].k == "mem"):
        fail("invalid operands for lea", c.line)
    return spec(c, [0x8d], o[0].reg.num, o[1], o[0].reg.bits, [], [o[0]])

# default stack operand size: 16 (real mode) / 32 / 64
func stack_osz(c):
    return c.bits

func h_push(c, o):
    need_ops(c, "push", o, 1)
    let a = o[0]
    let dflt = c.bits
    if is_gpr(a):
        let sz = a.reg.bits
        if sz == 8 or (sz == 64 and c.bits != 64) or (sz == 32 and c.bits == 64):
            fail("invalid operand size for push", c.line)
        return build(c, {opc: [0x50], opreg: a.reg.num, opsz: sz, norexw: true})
    if a.k == "reg" and a.reg.cls == "seg":
        let n = a.reg.name
        if c.bits == 64 and (n == "es" or n == "cs" or n == "ss" or n == "ds"):
            fail("push " .. n .. " is not valid in 64-bit mode", c.line)
        let opc = {es: [0x06], cs: [0x0e], ss: [0x16], ds: [0x1e], fs: [0x0f, 0xa0], gs: [0x0f, 0xa8]}[n]
        return build(c, {opc: opc, opsz: 0})
    if a.k == "imm":
        let sz = a.size if a.size > 0 else dflt
        if is_const(a) and fits8(a.v):
            return build(c, {opc: [0x6a], opsz: 0, p66: (sz == 16 and c.bits != 16) or (sz == 32 and c.bits == 16), imm: le(a.v, 1)})
        let isz = 16 if sz == 16 else 32
        return build(c, {opc: [0x68], opsz: 0, p66: (sz == 16 and c.bits != 16) or (sz == 32 and c.bits == 16), imm: le(a.v, isz // 8)})
    if a.k == "mem":
        let sz = a.size if a.size > 0 else dflt
        return build(c, {opc: [0xff], regf: 6, rm: a, opsz: sz, norexw: true})
    fail("invalid operand for push", c.line)

func h_pop(c, o):
    need_ops(c, "pop", o, 1)
    let a = o[0]
    if is_gpr(a):
        let sz = a.reg.bits
        if sz == 8 or (sz == 64 and c.bits != 64) or (sz == 32 and c.bits == 64):
            fail("invalid operand size for pop", c.line)
        return build(c, {opc: [0x58], opreg: a.reg.num, opsz: sz, norexw: true})
    if a.k == "reg" and a.reg.cls == "seg":
        let n = a.reg.name
        if n == "cs":
            fail("pop cs is not valid", c.line)
        if c.bits == 64 and (n == "es" or n == "ss" or n == "ds"):
            fail("pop " .. n .. " is not valid in 64-bit mode", c.line)
        let opc = {es: [0x07], ss: [0x17], ds: [0x1f], fs: [0x0f, 0xa1], gs: [0x0f, 0xa9]}[n]
        return build(c, {opc: opc, opsz: 0})
    if a.k == "mem":
        let sz = a.size if a.size > 0 else c.bits
        return build(c, {opc: [0x8f], regf: 0, rm: a, opsz: sz, norexw: true})
    fail("invalid operand for pop", c.line)

func h_incdec(c, n, o):
    need_ops(c, "inc/dec", o, 1)
    let a = o[0]
    if not is_rm(a):
        fail("invalid operand", c.line)
    let size = pick_size(c, a, nil)
    if size == 0:
        fail("operation size not specified", c.line)
    if is_gpr(a) and size != 8 and c.bits != 64:
        return build(c, {opc: [0x40 + 8 * n], opreg: a.reg.num, opsz: size})
    return spec(c, [0xfe if size == 8 else 0xff], n, a, size, [], [a])

func h_group3(c, n, o):
    need_ops(c, "group3", o, 1)
    let a = o[0]
    if not is_rm(a):
        fail("invalid operand", c.line)
    let size = pick_size(c, a, nil)
    if size == 0:
        fail("operation size not specified", c.line)
    return spec(c, [0xf6 if size == 8 else 0xf7], n, a, size, [], [a])

func h_imul(c, o):
    need_ops(c, "imul", o, 1, 3)
    if len(o) == 1:
        return h_group3(c, 5, o)
    let a = o[0]
    let b = o[1]
    if not is_gpr(a) or a.reg.bits == 8:
        fail("invalid operands for imul", c.line)
    let size = a.reg.bits
    if len(o) == 2 and b.k == "imm":
        return h_imul(c, [a, a, b])
    if len(o) == 2:
        if not is_rm(b):
            fail("invalid operands for imul", c.line)
        return spec(c, [0x0f, 0xaf], a.reg.num, b, size, [], [a, b])
    let m = o[1]
    let im = o[2]
    if not is_rm(m) or im.k != "imm":
        fail("invalid operands for imul", c.line)
    if is_const(im) and fits8s(im.v, size):
        return spec(c, [0x6b], a.reg.num, m, size, le(im.v, 1), [a, m])
    return spec(c, [0x69], a.reg.num, m, size, imm_bytes(c, im, size), [a, m])

func h_test(c, o):
    need_ops(c, "test", o, 2)
    let a = o[0]
    let b = o[1]
    if b.k == "imm":
        let size = pick_size(c, a, nil)
        if size == 0:
            fail("operation size not specified", c.line)
        if is_gpr(a) and a.reg.num == 0:
            return spec(c, [0xa8 if size == 8 else 0xa9], 0, nil, size, le(b.v, 1) if size == 8 else imm_bytes(c, b, size), [a])
        return spec(c, [0xf6 if size == 8 else 0xf7], 0, a, size, le(b.v, 1) if size == 8 else imm_bytes(c, b, size), [a])
    let size = pick_size(c, a, b)
    if size == 0:
        fail("operation size not specified", c.line)
    let w = 0 if size == 8 else 1
    if is_gpr(b) and is_rm(a):
        return spec(c, [0x84 + w], b.reg.num, a, size, [], [a, b])
    if is_gpr(a) and b.k == "mem":
        return spec(c, [0x84 + w], a.reg.num, b, size, [], [a])
    fail("invalid operands for test", c.line)

func h_shift(c, n, o):
    need_ops(c, "shift", o, 2)
    let a = o[0]
    let b = o[1]
    if not is_rm(a):
        fail("invalid operands", c.line)
    let size = pick_size(c, a, nil)
    if size == 0:
        fail("operation size not specified", c.line)
    let w = 0 if size == 8 else 1
    if b.k == "reg" and b.reg.name == "cl":
        return spec(c, [0xd2 + w], n, a, size, [], [a])
    if b.k != "imm":
        fail("shift count must be cl or an immediate", c.line)
    if is_const(b) and b.v == 1:
        return spec(c, [0xd0 + w], n, a, size, [], [a])
    return spec(c, [0xc0 + w], n, a, size, le(b.v, 1), [a])

func h_shxd(c, base, o):
    need_ops(c, "shld/shrd", o, 3)
    let a = o[0]
    let b = o[1]
    let k = o[2]
    if not (is_rm(a) and is_gpr(b)):
        fail("invalid operands", c.line)
    let size = b.reg.bits
    if k.k == "reg" and k.reg.name == "cl":
        return spec(c, [0x0f, base + 1], b.reg.num, a, size, [], [a, b])
    return spec(c, [0x0f, base], b.reg.num, a, size, le(k.v, 1), [a, b])

func h_io(c, mn, o):
    need_ops(c, mn, o, 2)
    if mn == "in":
        let a = o[0]
        let p = o[1]
        if not (is_gpr(a) and a.reg.num == 0):
            fail("in needs al / ax / eax", c.line)
        let size = a.reg.bits
        if p.k == "reg" and p.reg.name == "dx":
            return build(c, {opc: [0xec if size == 8 else 0xed], opsz: size})
        return build(c, {opc: [0xe4 if size == 8 else 0xe5], opsz: size, imm: le(p.v, 1)})
    let p = o[0]
    let a = o[1]
    if not (is_gpr(a) and a.reg.num == 0):
        fail("out needs al / ax / eax", c.line)
    let size = a.reg.bits
    if p.k == "reg" and p.reg.name == "dx":
        return build(c, {opc: [0xee if size == 8 else 0xef], opsz: size})
    return build(c, {opc: [0xe6 if size == 8 else 0xe7], opsz: size, imm: le(p.v, 1)})

func h_movx(c, signed, o):
    need_ops(c, "movzx/movsx", o, 2)
    let a = o[0]
    let b = o[1]
    if not is_gpr(a) or a.reg.bits == 8:
        fail("invalid destination", c.line)
    let ss = b.reg.bits if b.k == "reg" else b.size
    if ss == 0:
        fail("operation size not specified", c.line)
    if ss >= a.reg.bits:
        fail("source operand must be smaller than the destination", c.line)
    let opc = [0x0f, (0xbe if signed else 0xb6) + (0 if ss == 8 else 1)]
    return spec(c, opc, a.reg.num, b, a.reg.bits, [], [a, b])

func h_movsxd(c, o):
    need_ops(c, "movsxd", o, 2)
    if c.bits != 64 or not is_gpr(o[0]):
        fail("movsxd needs 64-bit mode", c.line)
    return spec(c, [0x63], o[0].reg.num, o[1], o[0].reg.bits, [], [o[0], o[1]])

func h_setcc(c, cc, o):
    need_ops(c, "setcc", o, 1)
    return spec(c, [0x0f, 0x90 + cc], 0, o[0], 8, [], [o[0]])

func h_cmov(c, cc, o):
    need_ops(c, "cmovcc", o, 2)
    if not is_gpr(o[0]):
        fail("invalid operands", c.line)
    return spec(c, [0x0f, 0x40 + cc], o[0].reg.num, o[1], o[0].reg.bits, [], [o[0], o[1]])

func h_bt(c, n, o):
    need_ops(c, "bt", o, 2)
    let a = o[0]
    let b = o[1]
    if b.k == "imm":
        let size = pick_size(c, a, nil)
        if size == 0:
            fail("operation size not specified", c.line)
        return spec(c, [0x0f, 0xba], n + 4, a, size, le(b.v, 1), [a])
    if not is_gpr(b):
        fail("invalid operands", c.line)
    return spec(c, [0x0f, 0xa3 + n * 8], b.reg.num, a, b.reg.bits, [], [b])

func h_rr(c, opc, o, swap):
    # reg, r/m  (swap: r/m, reg)
    need_ops(c, "instruction", o, 2)
    let r = o[1] if swap else o[0]
    let m = o[0] if swap else o[1]
    if not is_gpr(r) or not is_rm(m):
        fail("invalid operands", c.line)
    return spec(c, opc, r.reg.num, m, r.reg.bits, [], [r, m])

func h_sys(c, opc, ext, o, varsz = false):
    need_ops(c, "system instruction", o, 1)
    let osz = 0
    if varsz and is_gpr(o[0]):
        osz = o[0].reg.bits
    return build(c, {opc: opc, regf: ext, rm: o[0], opsz: osz, bregs: []})

func h_str_ops(c, mn):
    let e = SIZED[mn]
    let sz = e[1]
    let out = []
    if sz == 16 and c.bits != 16:
        out.append(0x66)
    elif sz == 32 and c.bits == 16:
        out.append(0x66)
    elif sz == 64:
        if c.bits != 64 and mn != "pushfq" and mn != "popfq":
            fail("'" .. mn .. "' needs 64-bit mode", c.line)
        if mn != "pushfq" and mn != "popfq":
            out.append(0x48)
    out.append(e[0])
    return out

# relative branches ----------------------------------------------------------------------------------------
func rel_bytes(v, n):
    return le(v, n)

func jkey(c):
    return to_string(c.sid) .. ":" .. to_string(c.titer)

func h_jmpcall(c, mn, o):
    need_ops(c, mn, o, 1)
    let a = o[0]
    let isjmp = mn == "jmp"
    if a.k == "far":
        let osz = a.size if a.size > 0 else mode_osz(c)
        if c.bits == 64:
            fail("direct far jumps are not valid in 64-bit mode", c.line)
        let out = []
        if (osz == 16 and c.bits != 16) or (osz == 32 and c.bits == 16):
            out.append(0x66)
        out.append(0xea if isjmp else 0x9a)
        for b in le(a.off_v.v, osz // 8):
            out.append(b)
        for b in le(a.seg_v.v, 2):
            out.append(b)
        return out
    if a.k == "mem" or a.k == "reg":
        if a.k == "reg" and (a.reg.cls != "gpr" or a.reg.bits == 8):
            fail("invalid operand", c.line)
        if a.far:
            let osz = a.size if a.size > 0 else mode_osz(c)
            return build(c, {opc: [0xff], regf: 5 if isjmp else 3, rm: a, opsz: osz, p66: (osz == 16 and c.bits != 16) or (osz == 32 and c.bits == 16), norexw: true})
        let osz = a.reg.bits if a.k == "reg" else (a.size if a.size > 0 else c.bits)
        if osz == 64 and c.bits != 64:
            fail("64-bit operand in non-64-bit mode", c.line)
        if c.bits == 64 and osz != 64:
            fail("only 64-bit indirect jumps and calls are valid in 64-bit mode", c.line)
        return build(c, {opc: [0xff], regf: 4 if isjmp else 2, rm: a, opsz: osz, norexw: true, bregs: []})
    # direct near / short
    let target = a.v
    let w = 2 if c.bits == 16 else 4
    if c.bits == 16 and a.size == 32:
        w = 4
    let pfx = []
    if (w == 4 and c.bits == 16):
        pfx.append(0x66)
    if isjmp:
        let key = jkey(c)
        let prev = c.jsz[key] if has(c.jsz, key) else "short"
        let want = prev
        if a.near:
            want = "near"
        elif a.u:
            want = prev
        elif prev != "near":
            let d = target - (c.here + 2)
            want = "short" if fits8(d) else "near"
        if a.short:
            want = "short"
        c.jsz[key] = want
        if want == "short":
            return cat([0xeb], rel_bytes(target - (c.here + 2), 1))
        let len = len(pfx) + 1 + w
        return cat(pfx, [0xe9], rel_bytes(target - (c.here + len), w))
    let len = len(pfx) + 1 + w
    return cat(pfx, [0xe8], rel_bytes(target - (c.here + len), w))

func h_jcc(c, cc, o):
    need_ops(c, "jcc", o, 1)
    let a = o[0]
    if a.k != "imm":
        fail("invalid operand for a conditional jump", c.line)
    let target = a.v
    let key = jkey(c)
    let prev = c.jsz[key] if has(c.jsz, key) else "short"
    let want = prev
    if a.near:
        want = "near"
    elif a.u:
        want = prev
    elif prev != "near":
        let d = target - (c.here + 2)
        want = "short" if fits8(d) else "near"
    if a.short:
        want = "short"
    c.jsz[key] = want
    if want == "short":
        return cat([0x70 + cc], rel_bytes(target - (c.here + 2), 1))
    let w = 2 if c.bits == 16 else 4
    return cat([0x0f, 0x80 + cc], rel_bytes(target - (c.here + 2 + w), w))

func h_loop(c, op, o):
    need_ops(c, "loop", o, 1)
    return cat([op], rel_bytes(o[0].v - (c.here + 2), 1))

func h_jcxz(c, mn, o):
    need_ops(c, mn, o, 1)
    let want = 16 if mn == "jcxz" else (32 if mn == "jecxz" else 64)
    if (c.bits == 64 and mn == "jcxz") or (c.bits != 64 and mn == "jrcxz"):
        fail("'" .. mn .. "' is not valid in " .. to_string(c.bits) .. "-bit mode", c.line)
    let pfx = []
    if want != c.bits:
        pfx.append(0x67)
    return cat(pfx, [0xe3], rel_bytes(o[0].v - (c.here + len(pfx) + 2), 1))

func h_int(c, o):
    need_ops(c, "int", o, 1)
    return cat([0xcd], le(o[0].v, 1))

func h_ret(c, op, o):
    if len(o) == 0:
        return [op + 1]
    return cat([op], le(o[0].v, 2))

func h_enter(c, o):
    need_ops(c, "enter", o, 2)
    return cat([0xc8], le(o[0].v, 2), le(o[1].v, 1))

func h_bswap(c, o):
    need_ops(c, "bswap", o, 1)
    if not is_gpr(o[0]) or o[0].reg.bits < 32:
        fail("bswap needs a 32 / 64-bit register", c.line)
    return build(c, {opc: [0x0f, 0xc8], opreg: o[0].reg.num, opsz: o[0].reg.bits})

func h_ext(c, extra, opc, o):
    need_ops(c, "instruction", o, 2)
    if not is_gpr(o[0]):
        fail("invalid operands", c.line)
    return build(c, {opc: opc, regf: o[0].reg.num, rm: o[1], opsz: o[0].reg.bits, extra: extra, bregs: bregs_of(o)})

func setup_mnem():
    for nm in ALU:
        let n = ALU[nm]
        MNEM[nm] = (c, o) => h_alu(c, n, o)
    for nm in SHIFT:
        let n = SHIFT[nm]
        MNEM[nm] = (c, o) => h_shift(c, n, o)
    MNEM["mov"] = h_mov
    MNEM["xchg"] = h_xchg
    MNEM["lea"] = h_lea
    MNEM["push"] = h_push
    MNEM["pop"] = h_pop
    MNEM["inc"] = (c, o) => h_incdec(c, 0, o)
    MNEM["dec"] = (c, o) => h_incdec(c, 1, o)
    MNEM["not"] = (c, o) => h_group3(c, 2, o)
    MNEM["neg"] = (c, o) => h_group3(c, 3, o)
    MNEM["mul"] = (c, o) => h_group3(c, 4, o)
    MNEM["div"] = (c, o) => h_group3(c, 6, o)
    MNEM["idiv"] = (c, o) => h_group3(c, 7, o)
    MNEM["imul"] = h_imul
    MNEM["test"] = h_test
    MNEM["shld"] = (c, o) => h_shxd(c, 0xa4, o)
    MNEM["shrd"] = (c, o) => h_shxd(c, 0xac, o)
    MNEM["in"] = (c, o) => h_io(c, "in", o)
    MNEM["out"] = (c, o) => h_io(c, "out", o)
    MNEM["movzx"] = (c, o) => h_movx(c, false, o)
    MNEM["movsx"] = (c, o) => h_movx(c, true, o)
    MNEM["movsxd"] = h_movsxd
    for nm in CC:
        let cc = CC[nm]
        MNEM["j" .. nm] = (c, o) => h_jcc(c, cc, o)
        MNEM["set" .. nm] = (c, o) => h_setcc(c, cc, o)
        MNEM["cmov" .. nm] = (c, o) => h_cmov(c, cc, o)
    MNEM["jmp"] = (c, o) => h_jmpcall(c, "jmp", o)
    MNEM["call"] = (c, o) => h_jmpcall(c, "call", o)
    MNEM["loop"] = (c, o) => h_loop(c, 0xe2, o)
    MNEM["loope"] = (c, o) => h_loop(c, 0xe1, o)
    MNEM["loopz"] = (c, o) => h_loop(c, 0xe1, o)
    MNEM["loopne"] = (c, o) => h_loop(c, 0xe0, o)
    MNEM["loopnz"] = (c, o) => h_loop(c, 0xe0, o)
    MNEM["jcxz"] = (c, o) => h_jcxz(c, "jcxz", o)
    MNEM["jecxz"] = (c, o) => h_jcxz(c, "jecxz", o)
    MNEM["jrcxz"] = (c, o) => h_jcxz(c, "jrcxz", o)
    MNEM["int"] = h_int
    MNEM["ret"] = (c, o) => h_ret(c, 0xc2, o)
    MNEM["retn"] = (c, o) => h_ret(c, 0xc2, o)
    MNEM["retf"] = (c, o) => h_ret(c, 0xca, o)
    MNEM["enter"] = h_enter
    MNEM["bswap"] = h_bswap
    MNEM["bt"] = (c, o) => h_bt(c, 0, o)
    MNEM["bts"] = (c, o) => h_bt(c, 1, o)
    MNEM["btr"] = (c, o) => h_bt(c, 2, o)
    MNEM["btc"] = (c, o) => h_bt(c, 3, o)
    MNEM["bsf"] = (c, o) => h_rr(c, [0x0f, 0xbc], o, false)
    MNEM["bsr"] = (c, o) => h_rr(c, [0x0f, 0xbd], o, false)
    MNEM["xadd"] = (c, o) => h_rr(c, [0x0f, 0xc1], o, true)
    MNEM["cmpxchg"] = (c, o) => h_rr(c, [0x0f, 0xb1], o, true)
    MNEM["popcnt"] = (c, o) => h_ext(c, 0xf3, [0x0f, 0xb8], o)
    MNEM["lzcnt"] = (c, o) => h_ext(c, 0xf3, [0x0f, 0xbd], o)
    MNEM["tzcnt"] = (c, o) => h_ext(c, 0xf3, [0x0f, 0xbc], o)
    MNEM["lgdt"] = (c, o) => h_sys(c, [0x0f, 0x01], 2, o)
    MNEM["lidt"] = (c, o) => h_sys(c, [0x0f, 0x01], 3, o)
    MNEM["sgdt"] = (c, o) => h_sys(c, [0x0f, 0x01], 0, o)
    MNEM["sidt"] = (c, o) => h_sys(c, [0x0f, 0x01], 1, o)
    MNEM["lldt"] = (c, o) => h_sys(c, [0x0f, 0x00], 2, o)
    MNEM["ltr"] = (c, o) => h_sys(c, [0x0f, 0x00], 3, o)
    MNEM["sldt"] = (c, o) => h_sys(c, [0x0f, 0x00], 0, o, true)
    MNEM["str"] = (c, o) => h_sys(c, [0x0f, 0x00], 1, o, true)
    MNEM["verr"] = (c, o) => h_sys(c, [0x0f, 0x00], 4, o)
    MNEM["verw"] = (c, o) => h_sys(c, [0x0f, 0x00], 5, o)
    MNEM["smsw"] = (c, o) => h_sys(c, [0x0f, 0x01], 4, o, true)
    MNEM["lmsw"] = (c, o) => h_sys(c, [0x0f, 0x01], 6, o)
    MNEM["invlpg"] = (c, o) => h_sys(c, [0x0f, 0x01], 7, o)
    MNEM["cmpxchg8b"] = (c, o) => h_sys(c, [0x0f, 0xc7], 1, o)
    MNEM["cmpxchg16b"] = (c, o) => build(c, {opc: [0x0f, 0xc7], regf: 1, rm: o[0], opsz: 64})
setup_mnem()

# ---- SSE / SSE2 (scalar and packed floating point, integer SIMD) --------------------------------------
# name: [mandatory prefix (0: none), opcode, kind, store opcode]; kinds: x = xmm, xmm/m128; xi = with imm8; cx = xmm, r/m32|64; xc = r32|64, xmm/m
const SSE = {
    movaps: [0, [0x0f, 0x28], "x", [0x0f, 0x29]], movups: [0, [0x0f, 0x10], "x", [0x0f, 0x11]],
    movapd: [0x66, [0x0f, 0x28], "x", [0x0f, 0x29]], movupd: [0x66, [0x0f, 0x10], "x", [0x0f, 0x11]],
    movss: [0xf3, [0x0f, 0x10], "x", [0x0f, 0x11]], movsd: [0xf2, [0x0f, 0x10], "x", [0x0f, 0x11]],
    movdqa: [0x66, [0x0f, 0x6f], "x", [0x0f, 0x7f]], movdqu: [0xf3, [0x0f, 0x6f], "x", [0x0f, 0x7f]],
    movlps: [0, [0x0f, 0x12], "x", [0x0f, 0x13]], movhps: [0, [0x0f, 0x16], "x", [0x0f, 0x17]],
    movlpd: [0x66, [0x0f, 0x12], "x", [0x0f, 0x13]], movhpd: [0x66, [0x0f, 0x16], "x", [0x0f, 0x17]],
    andps: [0, [0x0f, 0x54], "x", nil], andpd: [0x66, [0x0f, 0x54], "x", nil], andnps: [0, [0x0f, 0x55], "x", nil], andnpd: [0x66, [0x0f, 0x55], "x", nil],
    orps: [0, [0x0f, 0x56], "x", nil], orpd: [0x66, [0x0f, 0x56], "x", nil], xorps: [0, [0x0f, 0x57], "x", nil], xorpd: [0x66, [0x0f, 0x57], "x", nil],
    ucomiss: [0, [0x0f, 0x2e], "x", nil], ucomisd: [0x66, [0x0f, 0x2e], "x", nil], comiss: [0, [0x0f, 0x2f], "x", nil], comisd: [0x66, [0x0f, 0x2f], "x", nil],
    cvtss2sd: [0xf3, [0x0f, 0x5a], "x", nil], cvtsd2ss: [0xf2, [0x0f, 0x5a], "x", nil], cvtps2pd: [0, [0x0f, 0x5a], "x", nil], cvtpd2ps: [0x66, [0x0f, 0x5a], "x", nil],
    cvtsi2ss: [0xf3, [0x0f, 0x2a], "cx", nil], cvtsi2sd: [0xf2, [0x0f, 0x2a], "cx", nil],
    cvttss2si: [0xf3, [0x0f, 0x2c], "xc", nil], cvttsd2si: [0xf2, [0x0f, 0x2c], "xc", nil], cvtss2si: [0xf3, [0x0f, 0x2d], "xc", nil], cvtsd2si: [0xf2, [0x0f, 0x2d], "xc", nil],
    pxor: [0x66, [0x0f, 0xef], "x", nil], por: [0x66, [0x0f, 0xeb], "x", nil], pand: [0x66, [0x0f, 0xdb], "x", nil], pandn: [0x66, [0x0f, 0xdf], "x", nil],
    paddb: [0x66, [0x0f, 0xfc], "x", nil], paddw: [0x66, [0x0f, 0xfd], "x", nil], paddd: [0x66, [0x0f, 0xfe], "x", nil], paddq: [0x66, [0x0f, 0xd4], "x", nil],
    psubb: [0x66, [0x0f, 0xf8], "x", nil], psubw: [0x66, [0x0f, 0xf9], "x", nil], psubd: [0x66, [0x0f, 0xfa], "x", nil], psubq: [0x66, [0x0f, 0xfb], "x", nil],
    pcmpeqb: [0x66, [0x0f, 0x74], "x", nil], pcmpeqw: [0x66, [0x0f, 0x75], "x", nil], pcmpeqd: [0x66, [0x0f, 0x76], "x", nil],
    pmuludq: [0x66, [0x0f, 0xf4], "x", nil], pmullw: [0x66, [0x0f, 0xd5], "x", nil], pmaddwd: [0x66, [0x0f, 0xf5], "x", nil],
    punpcklbw: [0x66, [0x0f, 0x60], "x", nil], punpcklwd: [0x66, [0x0f, 0x61], "x", nil], punpckldq: [0x66, [0x0f, 0x62], "x", nil], punpcklqdq: [0x66, [0x0f, 0x6c], "x", nil],
    pshufd: [0x66, [0x0f, 0x70], "xi", nil], pshuflw: [0xf2, [0x0f, 0x70], "xi", nil], pshufhw: [0xf3, [0x0f, 0x70], "xi", nil], shufps: [0, [0x0f, 0xc6], "xi", nil], shufpd: [0x66, [0x0f, 0xc6], "xi", nil]}
const SSE_ARITH = {add: 0x58, mul: 0x59, sub: 0x5c, min: 0x5d, div: 0x5e, max: 0x5f, sqrt: 0x51}
func setup_sse():
    for nm in SSE_ARITH:
        let op = SSE_ARITH[nm]
        SSE[nm .. "ps"] = [0, [0x0f, op], "x", nil]
        SSE[nm .. "pd"] = [0x66, [0x0f, op], "x", nil]
        SSE[nm .. "ss"] = [0xf3, [0x0f, op], "x", nil]
        SSE[nm .. "sd"] = [0xf2, [0x0f, op], "x", nil]
setup_sse()

func is_xmm(o):
    return o.k == "reg" and o.reg.cls == "xmm"

func h_sse(c, mn, o):
    let e = SSE[mn]
    let pre = e[0] if e[0] != 0 else nil
    let kind = e[2]
    if kind == "x" or kind == "xi":
        need_ops(c, mn, o, 2 if kind == "x" else 3, 3 if kind == "xi" else 2)
        let imm = []
        if kind == "xi":
            imm = le(o[2].v, 1)
        if is_xmm(o[0]) and (is_xmm(o[1]) or o[1].k == "mem"):
            return build(c, {opc: e[1], regf: o[0].reg.num, rm: o[1], opsz: 0, extra: pre, imm: imm})
        if o[0].k == "mem" and is_xmm(o[1]) and e[3] != nil:
            return build(c, {opc: e[3], regf: o[1].reg.num, rm: o[0], opsz: 0, extra: pre})
        fail("invalid operands for " .. mn, c.line)
    need_ops(c, mn, o, 2)
    if kind == "cx":
        if not is_xmm(o[0]):
            fail("invalid operands for " .. mn, c.line)
        let sz = o[1].reg.bits if o[1].k == "reg" else o[1].size
        if sz != 32 and sz != 64:
            fail("operation size not specified", c.line)
        return build(c, {opc: e[1], regf: o[0].reg.num, rm: o[1], opsz: 64 if sz == 64 else 0, extra: pre})
    if not (is_gpr(o[0]) and (is_xmm(o[1]) or o[1].k == "mem")) or o[0].reg.bits < 32:
        fail("invalid operands for " .. mn, c.line)
    return build(c, {opc: e[1], regf: o[0].reg.num, rm: o[1], opsz: 64 if o[0].reg.bits == 64 else 0, extra: pre})

func h_movdq(c, mn, o):
    need_ops(c, mn, o, 2)
    let a = o[0]
    let b = o[1]
    let wide = mn == "movq"
    if is_xmm(a) and (is_gpr(b) or (b.k == "mem" and not (wide and b.size != 32 and b.size != 0 and false))):
        if is_gpr(b):
            let sz = b.reg.bits
            if (wide and sz != 64) or (not wide and sz != 32):
                fail("invalid operand size for " .. mn, c.line)
            return build(c, {opc: [0x0f, 0x6e], regf: a.reg.num, rm: b, opsz: 64 if wide else 0, extra: 0x66})
        if wide:
            return build(c, {opc: [0x0f, 0x7e], regf: a.reg.num, rm: b, opsz: 0, extra: 0xf3})
        return build(c, {opc: [0x0f, 0x6e], regf: a.reg.num, rm: b, opsz: 0, extra: 0x66})
    if is_xmm(a) and is_xmm(b):
        if not wide:
            fail("invalid operands for movd", c.line)
        return build(c, {opc: [0x0f, 0x7e], regf: a.reg.num, rm: b, opsz: 0, extra: 0xf3})
    if is_xmm(b) and (is_gpr(a) or a.k == "mem"):
        if is_gpr(a):
            let sz = a.reg.bits
            if (wide and sz != 64) or (not wide and sz != 32):
                fail("invalid operand size for " .. mn, c.line)
            return build(c, {opc: [0x0f, 0x7e], regf: b.reg.num, rm: a, opsz: 64 if wide else 0, extra: 0x66})
        if wide:
            return build(c, {opc: [0x0f, 0xd6], regf: b.reg.num, rm: a, opsz: 0, extra: 0x66})
        return build(c, {opc: [0x0f, 0x7e], regf: b.reg.num, rm: a, opsz: 0, extra: 0x66})
    fail("invalid operands for " .. mn, c.line)

func setup_sse_mnem():
    for nm in SSE:
        MNEM[nm] = (c, o) => h_sse(c, nm, o)
    MNEM["movd"] = (c, o) => h_movdq(c, "movd", o)
    MNEM["movq"] = (c, o) => h_movdq(c, "movq", o)
    # movsd / cmpsd are also string instructions: no operands means the string form
    let sse_movsd = MNEM["movsd"]
    MNEM["movsd"] = (c, o) => (h_str_ops(c, "movsd") if len(o) == 0 else sse_movsd(c, o))
setup_sse_mnem()

# ---- statements ---------------------------------------------------------------------------------------
func is_kw(w):
    return REG_OR_KW(w)

func subst_defs(toks, defs):
    if len(defs) == 0:
        return toks
    for round in range(8):
        let out = []
        let changed = false
        for t in toks:
            if t[0] == "i" and has(defs, t[1]):
                for d in defs[t[1]]:
                    out.append(d)
                changed = true
            else:
                out.append(t)
        toks = out
        if not changed:
            break
    return toks

func parse_stmt(toks, ln, id):
    let st = {line: ln, id: id, label: nil, times: nil, pfx: [], mn: nil, ops: [], equ: nil}
    let i = 0
    if len(toks) > 0 and toks[0][0] == "i":
        let nxt = toks[1] if len(toks) > 1 else nil
        if nxt != nil and nxt[0] == "o" and nxt[1] == ":":
            st.label = toks[0][1]
            i = 2
        elif not is_kw(toks[0][1]) and (nxt == nil or (nxt[0] == "i" and ["db", "dw", "dd", "dq", "resb", "resw", "resd", "resq", "equ", "times", "incbin"].contains(nxt[1]))):
            st.label = toks[0][1]
            i = 1
    let rest = toks.slice(i)
    if len(rest) == 0:
        return st
    if rest[0][0] == "i" and rest[0][1] == "equ":
        st.equ = rest.slice(1)
        return st
    if rest[0][0] == "i" and rest[0][1] == "times":
        let j = 1
        while j < len(rest) and not (rest[j][0] == "i" and is_kw(rest[j][1])):
            j += 1
        st.times = rest.slice(1, j)
        rest = rest.slice(j)
    while len(rest) > 0 and rest[0][0] == "i" and has(PREFIXES, rest[0][1]):
        st.pfx.append(PREFIXES[rest[0][1]])
        rest = rest.slice(1)
    if len(rest) == 0:
        return st
    if rest[0][0] != "i":
        fail("instruction expected", ln)
    st.mn = rest[0][1]
    st.ops = split_commas(rest.slice(1))
    return st

func parse_source(src, defs):
    let stmts = []
    let lines = src.split("\n")
    let id = 0
    for k in range(len(lines)):
        let ln = k + 1
        let raw = lines[k]
        let trimmed = raw.trim()
        if trimmed.starts_with("%"):
            let parts = trimmed.split(" ").filter(w => len(w) > 0)
            if parts[0] == "%define" and len(parts) >= 2:
                defs[parts[1]] = tokenize(parts.slice(2).join(" "), ln)
            elif parts[0] == "%assign" and len(parts) >= 3:
                let c0 = {syms: {}, prev: {}, cn: {}, undef: [], last: "", here: 0, org0: 0, line: ln, bits: 16}
                let v = eval_toks(c0, subst_defs(tokenize(parts.slice(2).join(" "), ln), defs))
                defs[parts[1]] = [["n", v.v]]
            else:
                fail("unsupported preprocessor directive '" .. parts[0] .. "'", ln)
            continue
        let toks = subst_defs(tokenize(raw, ln), defs)
        if len(toks) >= 3 and toks[0][0] == "o" and toks[0][1] == "[" and toks[len(toks) - 1][0] == "o" and toks[len(toks) - 1][1] == "]" and toks[1][0] == "i" and DIRECTIVES.contains(toks[1][1]):
            toks = toks.slice(1, len(toks) - 1)
        if len(toks) == 0:
            continue
        stmts.append(parse_stmt(toks, ln, id))
        id += 1
    return stmts

# ---- passes --------------------------------------------------------------------------------------------
func data_bytes(c, st, unit):
    let out = []
    for toks in st.ops:
        if len(toks) == 1 and toks[0][0] == "s":
            let sb = toks[0][1]
            for i in range(len(sb)):
                out.append(sb[i])
            let pad = (unit - len(sb) % unit) % unit
            for i in range(pad):
                out.append(0)
        else:
            let v = eval_toks(c, toks)
            for b in le(v.v, unit):
                out.append(b)
    return out

func exec_body(c, st):
    let mn = st.mn
    if mn == nil:
        return nil
    let out = nil
    if mn == "bits" or mn == "use16" or mn == "use32" or mn == "use64":
        let n = 16 if mn == "use16" else (32 if mn == "use32" else (64 if mn == "use64" else eval_toks(c, st.ops[0]).v))
        if n != 16 and n != 32 and n != 64:
            fail("bits must be 16, 32 or 64", c.line)
        c.bits = n
        return nil
    if mn == "org":
        let v = eval_toks(c, st.ops[0]).v
        c.org = v
        if len(c.out) == 0:
            c.org0 = v
        return nil
    if mn == "db" or mn == "dw" or mn == "dd" or mn == "dq":
        out = data_bytes(c, st, {db: 1, dw: 2, dd: 4, dq: 8}[mn])
    elif mn == "resb" or mn == "resw" or mn == "resd" or mn == "resq":
        let unit = {resb: 1, resw: 2, resd: 4, resq: 8}[mn]
        let n = eval_toks(c, st.ops[0]).v * unit
        out = []
        for i in range(n):
            out.append(0)
    elif mn == "align" or mn == "alignb":
        let n = eval_toks(c, st.ops[0]).v
        let fill = 0x90 if mn == "align" else 0
        if len(st.ops) > 1:
            let ft = st.ops[1]
            if len(ft) > 0 and ft[0][0] == "i" and ft[0][1] == "db":
                ft = ft.slice(1)
            fill = eval_toks(c, ft).v
        out = []
        if n > 0:
            let pad = (n - (c.here % n)) % n
            for i in range(pad):
                out.append(fill & 255)
    elif mn == "default":
        if len(st.ops) > 0 and len(st.ops[0]) > 0:
            c.default_rel = st.ops[0][0][1] == "rel"
        return nil
    elif mn == "section" or mn == "segment" or mn == "global" or mn == "extern" or mn == "cpu" or mn == "absolute":
        return nil
    elif mn == "incbin":
        fail("incbin is not supported", c.line)
    else:
        let ops = []
        for toks in st.ops:
            ops.append(parse_operand(c, toks))
        if has(MNEM, mn):
            out = MNEM[mn](c, ops)
        elif has(SIMPLE, mn):
            if len(ops) > 0:
                fail("'" .. mn .. "' takes no operands", c.line)
            if (mn == "into" and c.bits == 64) or ((mn == "swapgs" or mn == "sysretq" or mn == "iretq" or mn == "retfq") and c.bits != 64):
                fail("'" .. mn .. "' is not valid in " .. to_string(c.bits) .. "-bit mode", c.line)
            out = SIMPLE[mn].copy()
        elif has(SIZED, mn):
            out = h_str_ops(c, mn)
        else:
            fail("unknown instruction '" .. mn .. "'", c.line)
    if len(st.pfx) > 0:
        out = cat(st.pfx, out)
    for b in out:
        c.out.append(b)
    return nil

func run_pass(c, stmts):
    c.out = []
    c.syms = {}
    c.undef = []
    c.last = ""
    c.bits = c.bits0
    c.org = c.org_init
    c.org0 = c.org_init
    c.default_rel = false
    for st in stmts:
        c.line = st.line
        c.sid = st.id
        c.titer = 0
        c.here = c.org + len(c.out)
        if st.label != nil:
            let name = st.label
            if name.starts_with(".") and not name.starts_with(".."):
                name = c.last .. name
            else:
                c.last = name
            if has(c.syms, name):
                fail("label '" .. name .. "' redefined", st.line)
            if st.equ != nil:
                let v = eval_toks(c, st.equ)
                c.syms[name] = v.v
                c.cn[name] = v.n
                continue
            c.syms[name] = c.here
        if st.times != nil:
            let cnt = eval_toks(c, st.times).v
            for it in range(cnt):
                c.titer = it
                c.here = c.org + len(c.out)
                exec_body(c, st)
        else:
            exec_body(c, st)

func same_syms(a, b):
    if len(a) != len(b):
        return false
    for k, v in a:
        if not has(b, k) or b[k] != v:
            return false
    return true

# assemble(source, {bits: 16, org: 0, defines: {NAME: value}}) -> {bytes, symbols, size, bits}
export func assemble(src, opts = {}):
    let defs = {}
    if has(opts, "defines"):
        for k, v in opts.defines:
            defs[k] = [["n", v]]
    let stmts = parse_source(src, defs)
    let c = {bits0: opts.bits if has(opts, "bits") else 16, org_init: opts.org if has(opts, "org") else 0, prev: {}, syms: {}, cn: {},
             jsz: {}, out: [], undef: [], last: "", line: 0, here: 0, org: 0, org0: 0, bits: 16, sid: 0, titer: 0, default_rel: false}
    let done = false
    for iter in range(60):
        run_pass(c, stmts)
        if same_syms(c.syms, c.prev):
            done = true
            break
        c.prev = c.syms
    if not done:
        fail("could not resolve label addresses (the code does not converge)")
    if len(c.undef) > 0:
        fail("undefined symbol '" .. c.undef[0] .. "'")
    return {bytes: c.out, symbols: c.syms, size: len(c.out), bits: c.bits, org: c.org_init}

# a boot sector helper: pads to 510 bytes and appends the 0x55 0xAA signature
export func boot_sector(src, opts = {}):
    let o = {bits: 16, org: 0x7c00}
    for k, v in opts:
        o[k] = v
    let r = assemble(src .. "\n times 510 - ($ - $$) db 0\n dw 0xaa55\n", o)
    return r

# assembler source -> a callable C-ABI function (x86-64 hosts; needs --allow-ffi and --allow-asm):
#   asm.function("lea rax, [rdi+rsi]\nret", "int64_t(int64_t, int64_t)")
export func function(src, decl):
    if ffi.abi() != "x86_64":
        throw error("RuntimeError", "asm.function needs an x86-64 host; assemble for the target and pass the bytes to ffi.asm")
    return ffi.asm(assemble(src, {bits: 64}).bytes, decl)
