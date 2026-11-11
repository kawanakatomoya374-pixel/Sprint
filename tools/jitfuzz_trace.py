#!/usr/bin/env python3
"""Differential fuzzer for the TraceJIT path builder: random `while` loops over int / float locals with if / elif / else, forward
jumps, comparisons, + - * // % and unary minus must print the same under the interpreter (SPRINT_JIT=0), the default JIT
configuration, the TraceJIT with f64 traces enabled, and a JIT that compiles at the first back edge.
usage: jitfuzz_trace.py SPRINT [COUNT] [SEED]   (a development tool; not part of the build)"""
import os, random, subprocess, sys, tempfile

def gen(rng, fl):
    ints = ["a", "b", "c"]
    flts = ["x", "y"] if fl else []
    def iexpr(d=0):
        r = rng.random()
        if d > 2 or r < 0.35:
            return rng.choice(ints + ["i", str(rng.choice([0, 1, 2, 3, 7, 8, 16, 100, -1, -3, 641, 1000003]))])
        if r < 0.45:   # an array read; the index is reduced to the array's length, except now and then (an IndexError)
            return "arr[%s]" % (("(%s) %% 8" % iexpr(d + 1)) if rng.random() < 0.95 else iexpr(d + 1))
        op = rng.choice(["+", "-", "*", "//", "%", "+", "-", "&", "|", "^", "<<", ">>", "~"])
        if op in ("&", "|", "^"):
            return "(%s %s %s)" % (iexpr(d + 1), op, iexpr(d + 1))
        if op == "~":
            return "(~%s)" % iexpr(d + 1)
        if op in ("<<", ">>"):   # a count in 0 .. 63 almost always; now and then anything (saturation, a negative count -> ValueError)
            cnt = rng.choice(["1", "3", "13", "31", "62", "63", "(%s & 31)" % iexpr(d + 1), "(%s %% 70)" % iexpr(d + 1)]) if rng.random() < 0.9 else iexpr(d + 1)
            return "(%s %s %s)" % ("(%s %% 1000003)" % iexpr(d + 1) if op == "<<" else iexpr(d + 1), op, cnt)
        if op in ("//", "%"):
            if rng.random() < 0.75:
                return "(%s %s %s)" % (iexpr(d + 1), op, rng.choice(["2", "3", "7", "8", "16", "5", "641", "1000", "-3", "-8"]))
            return "(%s %s (1 + (%s %% 5)))" % (iexpr(d + 1), op, iexpr(d + 1))   # a variable divisor, never 0 / -1... except by accident
        if op == "*":
            return "(%s * %s)" % (iexpr(d + 1), rng.choice(["2", "3", "-1", "7", "i"]))   # keeps values from overflowing quickly
        return "(%s %s %s)" % (iexpr(d + 1), op, iexpr(d + 1))
    def fexpr(d=0):
        r = rng.random()
        if d > 1 or r < 0.4:
            return rng.choice(flts + ["0.5", "1.5", "2.0", "-0.25"])
        op = rng.choice(["+", "-", "*"])
        return "(%s %s %s)" % (fexpr(d + 1), op, fexpr(d + 1))
    def cond():
        if flts and rng.random() < 0.3:
            return "%s %s %s" % (fexpr(1), rng.choice(["<", "<=", ">", ">=", "==", "!="]), fexpr(1))
        return "%s %s %s" % (iexpr(1), rng.choice(["<", "<=", ">", ">=", "==", "!="]), iexpr(1))
    def stmt(ind, depth):
        pad = " " * ind
        r = rng.random()
        if depth < 2 and r < 0.3:
            s = "%sif %s:\n%s" % (pad, cond(), block(ind + 4, depth + 1))
            if rng.random() < 0.4:
                s += "%selif %s:\n%s" % (pad, cond(), block(ind + 4, depth + 1))
            if rng.random() < 0.6:
                s += "%selse:\n%s" % (pad, block(ind + 4, depth + 1))
            return s
        if r < 0.45:
            return "%sarr[(%s) %% 8] = %s\n" % (pad, iexpr(1), iexpr())
        if flts and r < 0.6:
            return "%s%s = %s\n" % (pad, rng.choice(flts), fexpr())
        return "%s%s = %s\n" % (pad, rng.choice(ints), iexpr())
    def block(ind, depth):
        return "".join(stmt(ind, depth) for _ in range(rng.randint(1, 3)))
    body = "".join(stmt(8, 0) for _ in range(rng.randint(2, 5)))
    fdecl = "    let x = 0.5\n    let y = 1.5\n" if fl else ""
    ret = "return [a, b, c, arr" + (", x, y" if fl else "") + "]"
    n = rng.choice([300, 2000, 6000])
    if rng.random() < 0.3:   # the same loop over module-level variables
        top = "let a = 1\nlet b = 2\nlet c = 3\nlet arr = [1, 2, 3, 4, 5, 6, 7, 8]\n%slet i = 0\n" % fdecl.replace("    ", "")
        shown = "print(a, b, c, arr" + (", x, y" if fl else "") + ")\n"
        if rng.random() < 0.5:
            return top + "try:\n    while i < %d:\n%s        i += 1\ncatch e:\n    print(e.kind)\n%s" % (n, body, shown)
        rng_expr = rng.choice(["range(%d)" % n, "range(0, %d, 2)" % n, "range(%d, 0, -1)" % n])
        return top + "try:\n    for i in %s:\n%scatch e:\n    print(e.kind)\n%s" % (rng_expr, body, shown)
    pre = "func f(n):\n    let a = 1\n    let b = 2\n    let c = 3\n    let arr = [1, 2, 3, 4, 5, 6, 7, 8]\n%s" % fdecl
    if rng.random() < 0.5:   # a counted loop
        rng_expr = rng.choice(["range(n)", "range(n)", "range(0, n, 2)", "range(0, n, 3)", "range(n, 0, -1)", "range(n, 0, -2)"])
        return (pre + "    for i in %s:\n%s    %s\ntry:\n    print(f(%d))\ncatch e:\n    print(e.kind)\n") % (rng_expr, body, ret, n)
    return (pre + "    let i = 0\n    while i < n:\n%s        i += 1\n    %s\ntry:\n    print(f(%d))\ncatch e:\n    print(e.kind)\n") % (body, ret, n)

def run(sprint, path, env):
    e = dict(os.environ); e.update(env)
    r = subprocess.run([sprint, "run", path], capture_output=True, text=True, env=e, timeout=60)
    return r.returncode, r.stdout

def main():
    sprint = sys.argv[1]
    count = int(sys.argv[2]) if len(sys.argv) > 2 else 200
    seed = int(sys.argv[3]) if len(sys.argv) > 3 else 1
    rng = random.Random(seed)
    bad = 0
    compiled = rejected = demoted = 0
    modes = [{"SPRINT_TRACE_JIT_F64": "1"}, {"SPRINT_TRACE_JIT_F64": "1", "SPRINT_JIT_THRESHOLD": "2"}, {}]
    for k in range(count):
        src = gen(rng, rng.random() < 0.4)
        with tempfile.NamedTemporaryFile("w", suffix=".sp", delete=False) as f:
            f.write(src)
            path = f.name
        try:
            e = dict(os.environ); e.update({"SPRINT_TRACE_JIT_F64": "1", "SPRINT_TRACE_JIT_DEBUG": "1"})
            err = subprocess.run([sprint, "run", path], capture_output=True, text=True, env=e, timeout=60).stderr
            compiled += err.count("trace-jit: compiled"); rejected += err.count("trace-jit: rejected"); demoted += err.count("trace-jit: demoted")
            ref = run(sprint, path, {"SPRINT_JIT": "0"})
            for m in modes:
                got = run(sprint, path, m)
                if got != ref:
                    bad += 1
                    print("MISMATCH seed=%d case=%d mode=%s\n%s\nref=%r\ngot=%r" % (seed, k, m, src, ref, got))
                    break
        finally:
            os.unlink(path)
    print("traces compiled: %d, rejected: %d, demoted: %d" % (compiled, rejected, demoted))
    print("done, mismatches: %d" % bad)
    sys.exit(1 if bad else 0)

main()
