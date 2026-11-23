#!/usr/bin/env python3
"""Compare sprintmp3 against ffmpeg's mp3float decoder (needs ffmpeg with libmp3lame, numpy).
usage: python3 tools/mp3/check.py        (run from the repository root, after `make`)"""
import os, subprocess, sys, tempfile, wave
import numpy as np

SP = os.path.abspath("build/sprint")
tmp = tempfile.mkdtemp()
RUN = os.path.join(tmp, "run.sp")
open(RUN, "w").write("""import fs
import sys
import typed
import sprintmp3
let a = sprintmp3.decode(fs.read_bytes(sys.args[0]))
let n = len(a.samples)
let o = typed.u8(n * 2)
for i in range(n):
    let v = a.samples[i] & 0xffff
    o[2 * i] = v & 255
    o[2 * i + 1] = v >> 8
fs.write_bytes(sys.args[1], o)
print(a.sample_rate, a.channels, a.frames)
""")

sr = 44100
t = np.arange(sr * 3) / sr
rng = np.random.default_rng(1)
sig = 0.3 * np.sin(2 * np.pi * (200 + 1500 * t) * t) + 0.2 * np.sin(2 * np.pi * 3000 * t)
sig += 0.1 * rng.standard_normal(len(t)) * (np.sin(2 * np.pi * 2 * t) > 0.7)
for k in range(0, len(t), 11025):
    sig[k:k + 200] += 0.6 * rng.standard_normal(min(200, len(t) - k))
st = np.clip(np.stack([sig, 0.7 * np.roll(sig, 300) + 0.1 * np.sin(2 * np.pi * 440 * t)], 1), -1, 1)
src = os.path.join(tmp, "src.wav")
with wave.open(src, "wb") as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(sr)
    w.writeframes((st * 32767).astype("<i2").tobytes())

cases = {
    "stereo 128k": ["-b:a", "128k"], "joint 96k": ["-b:a", "96k", "-joint_stereo", "1"],
    "ms off 192k": ["-b:a", "192k", "-joint_stereo", "0"], "mono 64k": ["-b:a", "64k", "-ac", "1"],
    "vbr q2": ["-q:a", "2"], "48 kHz": ["-b:a", "160k", "-ar", "48000"], "32 kHz": ["-b:a", "96k", "-ar", "32000"],
    "MPEG-2 22.05k": ["-b:a", "48k", "-ar", "22050"], "MPEG-2 16k mono": ["-b:a", "32k", "-ar", "16000", "-ac", "1"],
    "MPEG-2.5 8k mono": ["-b:a", "16k", "-ar", "8000", "-ac", "1"],
}
bad = 0
for name, opt in cases.items():
    mp3 = os.path.join(tmp, "x.mp3"); f32 = os.path.join(tmp, "x.f32"); out = os.path.join(tmp, "x.s16")
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", src, "-write_xing", "0", "-id3v2_version", "0",
                    "-c:a", "libmp3lame"] + opt + [mp3], check=True)
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-c:a", "mp3float", "-i", mp3, "-f", "f32le", f32], check=True)
    subprocess.run([SP, "run", "--allow-read=" + tmp, "--allow-write=" + tmp, RUN, mp3, out], check=True, capture_output=True)
    ref = np.clip(np.fromfile(f32, "<f4") * 32768, -32768, 32767)
    me = np.fromfile(out, "<i2").astype(float)
    ok = len(ref) == len(me) and np.abs(ref - me).max() <= 2
    bad += not ok
    print("%-18s %s  samples %d  max |diff| %.2f" % (name, "ok " if ok else "BAD", len(me), np.abs(ref[:len(me)] - me[:len(ref)]).max()))
sys.exit(1 if bad else 0)
