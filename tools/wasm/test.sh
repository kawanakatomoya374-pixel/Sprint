#!/bin/sh
# Runs the conformance suite on build/sprint.wasm (node WASI) and compares the failures with tools/wasm/known_failures.txt:
# differences of the platform (musl libm rounding, ffi/asm, a different /etc), not bugs. New failures or newly fixed ones fail.
cd "$(dirname "$0")/../.." || exit 1
got=$(SPRINT=tools/wasm/sprint-wasm sh tests/run_tests.sh 2>&1 | grep '^FAIL' | sed 's/ (rc=.*//' | sort)
want=$(sort tools/wasm/known_failures.txt)
if [ "$got" != "$want" ]; then
    echo "test-wasm: failures differ from tools/wasm/known_failures.txt"
    echo "$got" | diff - tools/wasm/known_failures.txt
    exit 1
fi
echo "test-wasm: conformance suite passes on wasm ($(echo "$want" | wc -l) known platform differences)"
