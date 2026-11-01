# Sprint JIT optimization report

## Summary

This patch set makes conservative JIT improvements to Sprint 2.31.1. It was retained only after the full JIT regression suite and differential fuzzing passed.

- Geometric-mean speedup across 16 microbenchmarks: **1.013x** (+1.30%).
- Faster benchmark cases: **9/16**; slower cases: **7/16**.
- Largest improvements: integer loop, typed sieve, and array traversal.
- This is a targeted improvement, not a universal speedup; many results are within a few percent and may include measurement noise.

## Changes

1. **Cheaper loop-budget tick (`ST_tick`, `ST_tick1`)**: use one unsigned `sub` plus carry test instead of a separate zero comparison and decrement. On underflow, explicitly restore the visible instruction budget to zero before exiting, preserving the VM contract.
2. **Unit-step range stencils (`ST_range_up1`, `ST_range_dn1`, `_p` variants)**: specialize step `+1` / `-1`, where the end-condition proves the increment/decrement cannot overflow. When the loop variable is the pinned local, update its frame payload and pinned `rbp` mirror in the same stencil, avoiding an extra mirror-load stencil.
3. **Non-negative constant-modulo fast path (`ST_imod_m_np`)**: when dataflow proves the pinned loop variable is written only by a positive unit-step range, add an entry guard for non-negativity and use the unsigned reciprocal-multiply modulo path without a sign branch or signed-division fallback. Negative starts remain on the interpreter / guarded path until the proof applies; reassignment invalidates the proof.

## Benchmark method

- Baseline: unmodified source from the uploaded Sprint 2.31.1 archive (`build/sprint-baseline`). Optimized: this patch set (`build/sprint-optimized-safe`).
- Runtime JIT threshold: `SPRINT_JIT_THRESHOLD=1` for both binaries.
- Each sample starts a fresh process; wall time includes process startup and Sprint source loading.
- Baseline and optimized executions were alternated, pinned with `taskset -c 1`, five samples per version per benchmark. Reported values are sample medians.
- Benchmarks: `tools/bench/loop.sp`, `collatz.sp`, `fib.sp`, `closure.sp`, `oop.sp`, `sieve.sp`, `tsieve.sp`, `matmul.sp`, `tmatmul.sp`, `nbody.sp`, `natcall.sp`, `arr.sp`, `tbl.sp`, `tokenize.sp`, `wordfreq.sp`, `strcat.sp`.
- Geometric mean treats each benchmark equally; it is not a workload-weighted production estimate.

## Results

| Benchmark | Baseline median (s) | Optimized median (s) | Speedup | Change |
|---|---:|---:|---:|---:|
| `loop.sp` | 0.334115 | 0.302823 | 1.103x | -9.37% |
| `collatz.sp` | 0.188260 | 0.195560 | 0.963x | +3.88% |
| `fib.sp` | 0.176992 | 0.181347 | 0.976x | +2.46% |
| `closure.sp` | 0.072867 | 0.070893 | 1.028x | -2.71% |
| `oop.sp` | 0.068145 | 0.069134 | 0.986x | +1.45% |
| `sieve.sp` | 0.117090 | 0.117159 | 0.999x | +0.06% |
| `tsieve.sp` | 0.035215 | 0.031633 | 1.113x | -10.17% |
| `matmul.sp` | 0.039197 | 0.038692 | 1.013x | -1.29% |
| `tmatmul.sp` | 0.034887 | 0.034871 | 1.000x | -0.05% |
| `nbody.sp` | 0.231524 | 0.231988 | 0.998x | +0.20% |
| `natcall.sp` | 0.162641 | 0.165954 | 0.980x | +2.04% |
| `arr.sp` | 0.048132 | 0.045655 | 1.054x | -5.15% |
| `tbl.sp` | 0.160469 | 0.165017 | 0.972x | +2.83% |
| `tokenize.sp` | 0.186990 | 0.183531 | 1.019x | -1.85% |
| `wordfreq.sp` | 0.156288 | 0.155404 | 1.006x | -0.57% |
| `strcat.sp` | 1.018620 | 1.007939 | 1.011x | -1.05% |

## Correctness validation

- `make test-jit`: **304 passed, 0 failed**.
- `make test`: **304 passed, 0 failed**.
- Differential JIT-vs-interpreter fuzzer: 250 loop cases, 250 call cases, and 250 object cases; **0 mismatches**.
- Added `tests/cases/jit/jit_range_nonneg_mod.sp` covers negative-to-positive ranges, descending ranges, loop-variable reassignment, and signed integer boundary cases.

## Deliberately excluded experiment

A more aggressive optimization that kept the range iterator itself in `rbp` across the whole loop was tested and rejected. It could improve some loop paths, but early versions produced incorrect results around negative-start ranges, modulo specialization, and deoptimization through calls/inlined callees. The shipped patch does **not** contain this experimental path. It remains a possible future direction only after a more explicit deoptimization/state-reconstruction design and additional tests.

## Environment

- Sprint: 2.31.1
- Compiler: GCC 14.2.0
- CPU: AMD EPYC 9V74 (container exposed 3 logical CPUs)
- OS: Linux x86-64, kernel 6.18.57

Raw medians and all five samples per case are included in `sprint-jit-benchmark.csv`.

> Archive note: the historical raw-sample file `sprint-jit-benchmark.csv` referenced
> above was not present in the supplied source archive. The aggregate medians shown
> in this note are retained as historical documentation; the original per-run sample
> data cannot be reproduced from this archive.
