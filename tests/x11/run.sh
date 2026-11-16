#!/bin/sh
# X11 backend test: opens a window on a private Xvfb, injects input with XTest and checks the events and pixels.
# usage: tests/x11/run.sh path/to/sprint      (skipped when Xvfb or XTest is not available)
d=$(dirname "$0")
if ! command -v xvfb-run >/dev/null 2>&1 || ! python3 -c 'import ctypes; ctypes.CDLL("libXtst.so.6"); ctypes.CDLL("libX11.so.6")' >/dev/null 2>&1; then
    echo "test-x11: skipped (needs xvfb-run and libXtst)"
    exit 0
fi
tmp=$(mktemp)
got=$(xvfb-run -a sh -c "'$1' run --allow-window '$d/events.sp' > '$tmp' 2>&1 & pid=\$!; python3 '$d/inject.py'; wait \$pid; cat '$tmp'")
rm -f "$tmp"
if [ "$got" != "$(cat "$d/events.out")" ]; then
    echo "test-x11: FAILED"
    echo "$got" | diff - "$d/events.out"
    exit 1
fi
echo "test-x11: window, rendering, mouse (double click, wheel), keys and text verified"
