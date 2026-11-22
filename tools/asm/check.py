#!/usr/bin/env python3
"""Compares the Sprint assembler (stdlib/asm.sp) with NASM on a generated corpus, per instruction and bit mode.
usage: python3 tools/asm/check.py [-v] [bits ...]     (needs nasm and build/sprint)"""
import subprocess, sys, os, tempfile, itertools, re

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
R8 = ["al", "cl", "dl", "bl"]
R8H = ["ah", "ch", "dh", "bh"]
R16 = ["ax", "cx", "dx", "bx", "sp", "bp", "si", "di"]
R32 = ["eax", "ecx", "edx", "ebx", "esp", "ebp", "esi", "edi"]
R64 = ["rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15"]
R32X = R32 + ["r8d", "r9d", "r15d"]
R16X = R16 + ["r8w", "r15w"]
R8X = R8 + ["spl", "bpl", "sil", "dil", "r8b", "r15b"]
SEGS = ["es", "cs", "ss", "ds", "fs", "gs"]

def mems(bits):
    if bits == 16:
        return ["[bx]", "[si]", "[di]", "[bp]", "[bx+si]", "[bx+di]", "[bp+si]", "[bp+di]", "[bx+4]", "[bp+4]", "[si-2]", "[bx+si+300]",
                "[0x1234]", "[es:bx]", "[cs:di+8]", "[bp+0]", "[di+0x7f]", "[di+0x80]"]
    if bits == 32:
        return ["[eax]", "[ecx]", "[esp]", "[ebp]", "[eax+4]", "[ebp+0]", "[esp+8]", "[eax+ecx]", "[eax+ecx*4]", "[eax*2+0x10]", "[ebx+esi*8+0x1000]",
                "[0x12345678]", "[es:eax]", "[fs:0x10]", "[esp+ecx*2-4]", "[ebp+edi]", "[edi+0x80]", "[eax*8]"]
    return ["[rax]", "[rcx]", "[rsp]", "[rbp]", "[r12]", "[r13]", "[rax+4]", "[rbp+0]", "[rsp+8]", "[rax+rcx]", "[rax+rcx*4]", "[r8+r9*2+0x10]", "[rbx+rsi*8+0x1000]",
            "[0x12345678]", "[fs:0x10]", "[r12+rax]", "[r13+8]", "[eax]", "[rip+0x10]", "[rax*2+0x20]", "[gs:rax+rbx]", "[rdi+0x80]", "[r15+r14*8+0x7fffffff]"]

def regs(bits, size):
    if size == 8:
        return R8X if bits == 64 else R8 + R8H
    if size == 16:
        return R16X if bits == 64 else R16
    if size == 32:
        return R32X if bits == 64 else R32
    return R64

def corpus(bits):
    L = []
    sizes = [8, 16, 32] + ([64] if bits == 64 else [])
    kw = {8: "byte", 16: "word", 32: "dword", 64: "qword"}
    imm = {8: ["0", "1", "127", "-1", "255"], 16: ["0", "1", "127", "128", "-1", "-128", "0x1234", "65535"],
           32: ["0", "1", "127", "128", "-1", "0x12345678", "-0x80000000"], 64: ["0", "1", "127", "-1", "0x12345678", "-5"]}
    for op in ["add", "or", "adc", "sbb", "and", "sub", "xor", "cmp", "mov", "test", "xchg"]:
        for sz in sizes:
            rs = regs(bits, sz)
            pick = rs[:6] + rs[-2:]
            for a in pick:
                for b in pick[:5]:
                    L.append(f"{op} {a}, {b}")
                for m in mems(bits)[::2]:
                    L.append(f"{op} {a}, {m}")
                    L.append(f"{op} {m}, {a}")
                if op not in ("xchg",):
                    for i in imm[sz]:
                        L.append(f"{op} {a}, {i}")
            if op not in ("xchg",):
                for m in mems(bits)[::3]:
                    for i in imm[sz][:4]:
                        L.append(f"{op} {kw[sz]} {m}, {i}")
    for op in ["inc", "dec", "neg", "not", "mul", "div", "idiv", "imul"]:
        for sz in sizes:
            for a in regs(bits, sz)[:6]:
                L.append(f"{op} {a}")
            for m in mems(bits)[::3]:
                L.append(f"{op} {kw[sz]} {m}")
    for op in ["shl", "shr", "sar", "rol", "ror", "rcl", "rcr"]:
        for sz in sizes:
            for a in regs(bits, sz)[:4]:
                L += [f"{op} {a}, 1", f"{op} {a}, cl", f"{op} {a}, 3"]
            for m in mems(bits)[::4]:
                L += [f"{op} {kw[sz]} {m}, 1", f"{op} {kw[sz]} {m}, cl", f"{op} {kw[sz]} {m}, 5"]
    for sz in sizes[1:]:
        rs = regs(bits, sz)[:5]
        for a in rs:
            for b in rs[:3]:
                L += [f"imul {a}, {b}", f"imul {a}, {b}, 5", f"imul {a}, {b}, 1000", f"movzx {a}, {R8[1]}", f"bsf {a}, {b}", f"bsr {a}, {b}",
                      f"bt {a}, {b}", f"bts {a}, {b}", f"btr {a}, {b}", f"btc {a}, {b}", f"cmovz {a}, {b}", f"cmovl {a}, {b}", f"xadd {a}, {b}", f"cmpxchg {a}, {b}"]
            L += [f"bt {a}, 5", f"lea {a}, [{regs(bits, 16 if bits == 16 else (32 if bits == 32 else 64))[3]}+4]"]
            for m in mems(bits)[::2]:
                L += [f"lea {a}, {m}", f"movzx {a}, byte {m}", f"movsx {a}, byte {m}", f"cmovne {a}, {m}"]
                if sz == 32:
                    L += [f"movzx {a}, word {m}", f"movsx {a}, word {m}"]
    for sz in [16, 32] + ([64] if bits == 64 else []):
        for a in regs(bits, sz)[:6]:
            L += [f"movzx {a}, bl", f"movsx {a}, cl"]
            if sz != 16:
                L += [f"movzx {a}, bx", f"movsx {a}, dx"]
    for a in R8X[:4]:
        L += [f"set{c} {a}" for c in ("z", "ne", "l", "ge", "a")]
    # push / pop
    for sz in ([16] if bits == 16 else [16, 32] if bits == 32 else [16, 64]) + ([32] if bits == 16 else []):
        for a in regs(bits, sz)[:5]:
            L += [f"push {a}", f"pop {a}"]
    if bits == 16:
        L += ["push 5", "push 1000", "push word 5", "push dword 5", "push dword 100000", "push eax", "pop eax", "pushf", "pushfd", "popf", "popfd", "pusha", "popa", "pushad", "popad"]
        L += [f"push {s}" for s in SEGS] + [f"pop {s}" for s in SEGS if s != "cs"]
    elif bits == 32:
        L += ["push 5", "push 1000", "push word 5", "pushf", "popf", "pushfd", "popfd", "pusha", "popa", "pushad", "popad", "pushaw", "pushfw"]
        L += [f"push {s}" for s in SEGS] + [f"pop {s}" for s in SEGS if s != "cs"]
    else:
        L += ["push 5", "push 1000", "pushfq", "popfq", "pushf", "popf", "push fs", "push gs", "pop fs", "pop gs"]
    for m in mems(bits)[::2]:
        L += [f"push {kw[16 if bits == 16 else (32 if bits == 32 else 64)]} {m}", f"pop {kw[16 if bits == 16 else (32 if bits == 32 else 64)]} {m}"]
    # mov with segment / control registers
    for s in SEGS:
        L += [f"mov ax, {s}", f"mov {s}, ax", f"mov {s}, bx"] + [f"mov {s}, {m}" for m in mems(bits)[:3]] + [f"mov {m}, {s}" for m in mems(bits)[:3]]
        if bits != 64:
            L += [f"mov eax, {s}", f"mov {s}, eax"]
    for cr in ["cr0", "cr2", "cr3", "cr4"]:
        for r in (R32[:4] if bits != 64 else R64[:3] + ["r8", "r9"]):
            L += [f"mov {r}, {cr}", f"mov {cr}, {r}"]
    for dr in ["dr0", "dr3", "dr7"]:
        for r in (R32[:3] if bits != 64 else R64[:3]):
            L += [f"mov {r}, {dr}", f"mov {dr}, {r}"]
    L += ["mov al, [0x1234]", "mov [0x1234], al", "mov ax, [0x1234]", "mov [0x1234], ax", "mov eax, [0x1234]", "mov [0x1234], eax", "mov [es:0x10], al"]
    # control flow with absolute targets (no labels)
    L += ["ret", "ret 4", "retf", "retf 8", "iret", "int 0x10", "int 3", "int3", "into", "leave", "enter 16, 0"]
    L += ["jmp ax", "jmp bx", "call ax", "jmp [bx]", "call [bx]", "jmp word [bx]", "call word [bx]", "jmp far [bx]", "call far [bx]"]
    if bits == 16:
        L += ["jmp 0x1234:0x5678", "call 0x1234:0x5678", "jmp dword 0x8:0x12345", "jmp eax", "call eax", "jmp dword [bx]", "call dword [bx]", "jmp far dword [bx]"]
    elif bits == 32:
        L += ["jmp 0x8:0x12345678", "call 0x8:0x12345678", "jmp eax", "call eax", "jmp dword [eax]", "jmp far [eax]", "call far [eax]"]
    else:
        L += ["jmp rax", "call rax", "jmp qword [rax]", "call qword [rax+8]", "jmp r9", "call r10"]
    for op in ["lgdt", "lidt", "sgdt", "sidt", "invlpg", "lldt", "ltr", "sldt", "str", "smsw", "lmsw", "verr", "verw"]:
        for m in mems(bits)[:4]:
            L.append(f"{op} {m}")
    L += ["lldt ax", "ltr ax", "smsw ax", "lmsw ax", "sldt ax", "str ax", "sldt bx"]
    for io in ["in al, 0x60", "in ax, 0x60", "in al, dx", "in ax, dx", "in eax, dx", "in eax, 0x60", "out 0x60, al", "out 0x60, ax", "out dx, al", "out dx, ax", "out dx, eax", "out 0x60, eax"]:
        L.append(io)
    ns = ["nop", "hlt", "cli", "sti", "cld", "std", "clc", "stc", "cmc", "wait", "lahf", "sahf", "cpuid", "rdtsc", "rdmsr", "wrmsr", "syscall", "sysret", "ud2", "wbinvd",
          "invd", "clts", "pause", "xlatb", "lfence", "mfence", "sfence", "swapgs", "cbw", "cwde", "cwd", "cdq", "movsb", "movsw", "movsd", "cmpsb", "cmpsw", "cmpsd",
          "stosb", "stosw", "stosd", "lodsb", "lodsw", "lodsd", "scasb", "scasw", "scasd", "insb", "insw", "insd", "outsb", "outsw", "outsd",
          "rep movsb", "rep movsw", "rep movsd", "rep stosb", "rep stosw", "rep stosd", "repe cmpsb", "repne scasb", "lock inc dword [eax]", "rep insb", "rep outsw"]
    if bits == 64:
        ns += ["cdqe", "cqo", "movsq", "stosq", "lodsq", "scasq", "cmpsq", "rep movsq", "rep stosq", "iretq", "retfq"]
    L += ns
    for r in (R32 if bits != 64 else R32[:4] + ["r9d"]) + (R64[:3] if bits == 64 else []):
        L.append(f"bswap {r}")
    if bits == 64:
        L += ["movsxd rax, ebx", "movsxd rcx, dword [rax]", "movsxd r9, r10d", "mov rax, 0x123456789abc", "mov rax, 5", "mov rax, -5", "mov r9, 0x123456789abcdef0", "mov r9, 1"]
        L += ["xchg rax, rbx", "xchg r8, rax", "xchg rcx, rdx", "inc rax", "dec r9", "inc dword [rax]"]
        L += ["add al, spl", "mov sil, al", "mov dil, 5", "mov r8b, 5", "movzx eax, sil"]
    L += ["xchg ax, bx", "xchg bx, ax", "xchg eax, ebx", "xchg al, bl", "xchg [bx], al", "nop"]
    L += ["jcxz 0", "loop 0", "loope 0", "loopne 0"]
    xs = ["xmm0", "xmm1", "xmm7"] + (["xmm8", "xmm15"] if bits == 64 else [])
    two = ["movaps", "movups", "movapd", "movupd", "movss", "movsd", "movdqa", "movdqu", "andps", "andpd", "orps", "xorps", "xorpd", "ucomiss", "ucomisd", "comiss", "comisd",
           "cvtss2sd", "cvtsd2ss", "pxor", "por", "pand", "paddb", "paddd", "paddq", "psubd", "pcmpeqb", "pcmpeqd", "pmuludq", "punpcklbw", "punpckldq", "punpcklqdq"]
    two += [a + b for a in ("add", "sub", "mul", "div", "min", "max", "sqrt") for b in ("ps", "pd", "ss", "sd")]
    for op in two:
        for a in xs[:3]:
            for b in xs[:3]:
                L.append(f"{op} {a}, {b}")
            for m in mems(bits)[:4]:
                L.append(f"{op} {a}, {m}")
        if op.startswith("mov"):
            for m in mems(bits)[:3]:
                L.append(f"{op} {m}, xmm1")
        for a in xs[3:]:
            L.append(f"{op} {a}, xmm1")
    for op in ["pshufd", "shufps", "pshuflw"]:
        L += [f"{op} xmm1, xmm2, 0x1b", f"{op} xmm0, [{'bx' if bits == 16 else 'eax'}], 3"]
    for r in (R32[:3] + (R64[:2] + ["r9"] if bits == 64 else [])):
        for op in ["cvtsi2sd", "cvtsi2ss"]:
            L += [f"{op} xmm1, {r}"]
        L += [f"cvttsd2si {r}, xmm1", f"cvttss2si {r}, xmm2", f"cvtsd2si {r}, xmm0"]
        if len(r) == 3 and r.startswith("e") or r.endswith("d"):
            L += [f"movd xmm1, {r}", f"movd {r}, xmm1"]
        if r.startswith("r") and not r.endswith("d"):
            L += [f"movq xmm1, {r}", f"movq {r}, xmm1"]
    L += ["movq xmm1, xmm2", "movq xmm1, [" + ("bx" if bits == 16 else "eax") + "]", "movq [" + ("bx" if bits == 16 else "eax") + "], xmm1",
          "movd xmm1, [" + ("bx" if bits == 16 else "eax") + "]", "cvtsi2sd xmm1, dword [" + ("bx" if bits == 16 else "eax") + "]"]
    return L

def label_corpus(bits):
    return [f"""bits {bits}
org 0x100
start: jmp fwd
back: nop
  jne back
  jne fwd
  call back
  call fwd
  jmp short back
  jmp back
  loop back
fwd: mov ax, fwd
  times 200 nop
  jmp back
  je back
  mov bx, [fwd]
  cmp ax, fwd
  add ax, fwd + 4
end:
  jmp start
  jmp $
  times 510-($-$$) db 0
  dw 0xaa55
"""]

def nasm_lines(bits, lines, workdir):
    src = os.path.join(workdir, "c.asm")
    lst = os.path.join(workdir, "c.lst")
    with open(src, "w") as f:
        f.write(f"bits {bits}\n")
        for l in lines:
            f.write(l + "\n")
    # nasm stops at errors; retry line by line when the whole file fails
    r = subprocess.run(["nasm", "-f", "bin", src, "-o", os.path.join(workdir, "c.bin"), "-l", lst], capture_output=True, text=True)
    res = {}
    if r.returncode != 0:
        for i, l in enumerate(lines):
            with open(src, "w") as f:
                f.write(f"bits {bits}\n{l}\n")
            r1 = subprocess.run(["nasm", "-f", "bin", src, "-o", os.path.join(workdir, "c.bin")], capture_output=True, text=True)
            if r1.returncode == 0:
                res[i] = open(os.path.join(workdir, "c.bin"), "rb").read().hex()
            else:
                res[i] = "ERR"
        return res
    # parse the listing: lines "     N OFFSET HEXBYTES   source"
    prev_end = 0
    for ln in open(lst).read().split("\n"):
        m = re.match(r"\s*(\d+)\s+([0-9A-F]{8})\s+([0-9A-F]+)(-?)\s", ln)
        if m:
            n = int(m.group(1)) - 2   # line 1 is the bits directive (listing counts from 1)
            if 0 <= n < len(lines):
                res[n] = res.get(n, "") + m.group(3).lower()
    for i in range(len(lines)):
        res.setdefault(i, "")
    return res

def sprint_lines(bits, lines, workdir):
    p = os.path.join(workdir, "s.asm")
    open(p, "w").write("\n".join(lines) + "\n")
    r = subprocess.run([os.path.join(ROOT, "build/sprint"), "run", "--allow-read=" + workdir, os.path.join(ROOT, "tools/asm/lines.sp"), str(bits), p],
                       capture_output=True, text=True)
    out = r.stdout.split("\n")
    if r.returncode != 0:
        print("sprint failed:", r.stderr[:400])
    return out

def whole_programs():
    """Whole-file comparison on label-heavy programs (multi-pass sizing of jumps)."""
    bad = 0
    for bits in (16, 32, 64):
        for k, src in enumerate(label_corpus(bits)):
            with tempfile.TemporaryDirectory() as wd:
                a = os.path.join(wd, "p.asm")
                open(a, "w").write(src)
                r = subprocess.run(["nasm", "-f", "bin", a, "-o", os.path.join(wd, "n.bin")], capture_output=True, text=True)
                if r.returncode != 0:
                    print(f"whole[{bits}.{k}]: nasm failed: {r.stderr[:200]}")
                    continue
                r = subprocess.run([os.path.join(ROOT, "build/sprint"), "run", f"--allow-read={wd}", f"--allow-write={wd}", os.path.join(ROOT, "tools/asm/asm.sp"),
                                    "--bits", str(bits), a, os.path.join(wd, "s.bin")], capture_output=True, text=True)
                nb = open(os.path.join(wd, "n.bin"), "rb").read()
                try:
                    sb = open(os.path.join(wd, "s.bin"), "rb").read()
                except OSError:
                    print(f"whole[{bits}.{k}]: sprint failed: {r.stderr[:300]}")
                    bad += 1
                    continue
                if nb == sb:
                    print(f"whole[{bits}.{k}]: identical ({len(nb)} bytes)")
                else:
                    bad += 1
                    n = next((i for i in range(min(len(nb), len(sb))) if nb[i] != sb[i]), min(len(nb), len(sb)))
                    print(f"whole[{bits}.{k}]: DIFFER at byte {n}: nasm {nb[n:n+8].hex()} sprint {sb[n:n+8].hex()} (sizes {len(nb)} / {len(sb)})")
    return bad

def main():
    verbose = "-v" in sys.argv
    modes = [int(a) for a in sys.argv[1:] if a.isdigit()] or [16, 32, 64]
    bad_total = 0
    for bits in modes:
        lines = list(dict.fromkeys(corpus(bits)))
        with tempfile.TemporaryDirectory() as wd:
            nl = nasm_lines(bits, lines, wd)
            sl = sprint_lines(bits, lines, wd)
        diff = same = skipped = 0
        shown = 0
        for i, l in enumerate(lines):
            n = nl[i]
            s = sl[i] if i < len(sl) else "?"
            if n == "ERR":
                skipped += 1
                if not s.startswith("ERR") and verbose:
                    print(f"[{bits}] nasm rejects, sprint accepts: {l} -> {s}")
                continue
            if s == n:
                same += 1
            else:
                diff += 1
                if shown < 60:
                    print(f"[{bits}] {l!r}: nasm {n}  sprint {s}")
                    shown += 1
        print(f"bits {bits}: {same} identical, {diff} different, {skipped} rejected by nasm (of {len(lines)})")
        bad_total += diff
    bad_total += whole_programs()
    sys.exit(1 if bad_total else 0)

main()
