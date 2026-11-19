#!/usr/bin/env python3
"""What DeepFilterNet's plugin keeps of speech, measured.

    tools/measure/measure.py <set> [--plugin SO] [--work DIR] [--jobs N]
                             [--cases A,B] [--quantum N] [--assets DIR]

<set> is one of the three docs/DEEPFILTERNET.md publishes:

    strengths  six sets of the plugin's controls over speech from -20 to
               -50 dBFS under a quiet room's floor, dry and with a room's
               reverberation (*Quiet speech, measured*, its first bullets)
    levels     gentle, balanced and maximum at a fixed 6 dB SNR, from -10
               to -59 dBFS (its table)
    gain       balanced and maximum with 0, 12, 20 and 30 dB before the
               plugin and as much taken off after (*The gain either side of
               the plugin*)

Each run is the built plugin under tools/measure/dfhost.c, one quantum per
real-time period, as PipeWire's data thread paces a filter, so a set takes
about as long as its audio: some 23 seconds a run, --jobs at a time. A run
that drops a sample is run again, once; one that drops a sample twice is
said, and its row marked with a !.

The speech and the noise are the plugin's own fork's test clips, at the
commit packaging/arch/PKGBUILD pins, fetched once into the work directory and
refused unless each file's sha256 is the one below. --assets reads them from
a directory instead, under the same check.

Needs python3 with numpy, a C compiler, curl for the fetch, and the plugin:
/usr/lib/ladspa/libdeep_filter_ladspa.so where jayos-audio is installed,
or --plugin. Writes nothing outside the work directory, the system's
temporary directory by default. tests/shell/test-measure.sh runs it against a
stub plugin.
"""
import argparse, hashlib, json, os, re, shutil, subprocess, sys, tempfile, wave
from concurrent.futures import ThreadPoolExecutor

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
RATE = 48000
LEAD = 2 * RATE                # noise alone before the speech
FLOOR_DB = -50.0               # the strengths set's quiet room, RMS dBFS

# The two clips, by the name the fork gives them, and what each must hash to.
# A clip that changed under its name is a different measurement; these are
# the bytes the published tables were measured on (2026-11-19).
ASSETS = {
    "speech": ("clean_freesound_33711.wav", "2d885e9f45c0f9381aee09a397ecd160aff1875ffb75ebe2217d21c3511b0d5d"),
    "noise": ("noise_freesound_2530.wav", "cc774d58170fc5b8f143345ef8ff31583feef71f23f447336fdd56c8478d8a8a"),
}
FORK = "https://raw.githubusercontent.com/ismailivanov/DeepFilterNetPlus"

# The plugin's six controls, in the order each strength gives them, and the
# strengths: src/jayos-audio's presets, with three variants of maximum that
# tell which of its differences from balanced does what.
PORTS = ["Attenuation Limit (dB)", "Min processing threshold (dB)", "Max ERB processing threshold (dB)",
         "Max DF processing threshold (dB)", "Min Processing Buffer (frames)", "Post Filter Beta"]
STRENGTHS = {
    "gentle": (24, -15, 30, 20, 2, 0.02),
    "balanced": (70, -15, 30, 20, 2, 0.02),
    "maximum": (100, -15, 35, 35, 2, 0.05),
    "max, beta 0.02": (100, -15, 35, 35, 2, 0.02),
    "max, 30/20": (100, -15, 30, 20, 2, 0.05),
    "max, limit 70": (70, -15, 35, 35, 2, 0.05),
}


def sets():
    """Each set: the strengths it runs, and its cases as (name, speech dBFS,
    noise dBFS, dry or far, gain dB before the plugin)."""
    near = [("near", s) for s in (-20, -30, -40, -44, -47, -50)] + [("far", -30), ("far", -40)]
    level = [(-10, -16), (-44, -50), (-49, -55), (-54, -60), (-59, -65)]
    gain = [(-44, -50), (-54, -60), (-59, -65), (-64, -70), (-69, -75), (-10, -16), (-6, -36), (-3, -40)]
    return {
        "strengths": (list(STRENGTHS), [(f"{k}{-s}", s, FLOOR_DB, k, 0) for k, s in near]),
        "levels": (["gentle", "balanced", "maximum"], [(f"s{-s}n{-n}", s, n, "near", 0) for s, n in level]),
        "gain": (["balanced", "maximum"], [(f"s{-s}n{-n}g{g}", s, n, "near", g) for s, n in gain for g in (0, 12, 20, 30)]),
    }


def db(x):
    return 10 * np.log10(np.maximum(x, 1e-20))


def frames(x, n=960):
    m = len(x) // n
    return x[: m * n].reshape(m, n)


def active_rms(x):
    # A recording's level is its speech's, not its pauses': the RMS of the
    # 20 ms frames within 30 dB of the loudest, as a level meter that gates
    # on speech reads it.
    f = (frames(x) ** 2).mean(axis=1)
    return np.sqrt(f[db(f) > db(f.max()) - 30].mean())


def reverb(x, seed=1):
    # A room's tail: RT60 0.5 s, as much reverberant energy as direct -- a
    # talker a metre or two from a desk microphone rather than a hand's width.
    rng = np.random.default_rng(seed)
    t = np.arange(int(0.6 * RATE)) / RATE
    tail = rng.standard_normal(len(t)) * np.exp(-6.91 * t / 0.5)
    tail[: int(0.003 * RATE)] = 0
    tail /= np.sqrt((tail ** 2).sum())
    return np.convolve(x, np.concatenate([[1.0], tail[1:]]))[: len(x)]


def pinned_commit():
    text = open(os.path.join(ROOT, "packaging/arch/PKGBUILD")).read()
    m = re.search(r"^_commit=([0-9a-f]{40})$", text, re.M)
    if not m:
        sys.exit("measure: packaging/arch/PKGBUILD pins no _commit")
    return m.group(1)


def read_wav(path):
    # Mono at 48 kHz, as the plugin is run. A stereo clip is folded as
    # ffmpeg's -ac 1 folds it, each channel at -3 dB; its level is set from
    # its RMS afterwards, so only the shape of the fold matters.
    w = wave.open(path)
    if w.getframerate() != RATE or w.getsampwidth() != 2:
        sys.exit(f"measure: {path} is not 16-bit at {RATE} Hz")
    x = np.frombuffer(w.readframes(w.getnframes()), np.int16).astype(np.float64) / 32768
    x = x.reshape(-1, w.getnchannels())
    return x[:, 0] if x.shape[1] == 1 else x.sum(axis=1) / np.sqrt(2)


def assets(work, source, pins):
    out = {}
    os.makedirs(os.path.join(work, "assets"), exist_ok=True)
    for key, (name, want) in pins.items():
        path = os.path.join(source, name) if source else os.path.join(work, "assets", name)
        if not source and not os.path.exists(path):
            url = f"{FORK}/{pinned_commit()}/assets/{name}"
            print(f"fetching {url}", flush=True)
            subprocess.run(["curl", "-fsSL", "--max-time", "120", "-o", path + ".part", url], check=True)
            os.replace(path + ".part", path)
        got = hashlib.sha256(open(path, "rb").read()).hexdigest()
        if got != want:
            sys.exit(f"measure: {name} hashes to {got}, not the {want} the tables were measured on")
        out[key] = read_wav(path)
    return out


def host(work):
    exe = os.path.join(work, "dfhost")
    src = os.path.join(HERE, "dfhost.c")
    if not os.path.exists(exe) or os.path.getmtime(exe) < os.path.getmtime(src):
        cc = os.environ.get("CC") or shutil.which("cc") or shutil.which("gcc")
        if not cc:
            sys.exit("measure: no C compiler to build dfhost with")
        subprocess.run([cc, "-O2", "-o", exe, src, "-ldl"], check=True)
    return exe


def prepare(work, clips, cases):
    speech0, noise0 = clips["speech"], clips["noise"]
    total = LEAD + len(speech0)
    if len(noise0) < total:
        noise0 = np.tile(noise0, total // len(noise0) + 1)
    noise0 = noise0[:total]
    for name, s_db, n_db, kind, gain in cases:
        sp = reverb(speech0) if kind == "far" else speech0.copy()
        sp *= 10 ** (s_db / 20) / active_rms(sp)
        speech = np.concatenate([np.zeros(LEAD), sp])
        mix = speech + noise0 * 10 ** (n_db / 20) / np.sqrt((noise0 ** 2).mean())
        (mix * 10 ** (gain / 20)).astype(np.float32).tofile(os.path.join(work, f"in-{name}.f32"))
        speech.astype(np.float32).tofile(os.path.join(work, f"speech-{name}.f32"))


def tag_of(strength, case):
    return re.sub(r"[^a-z0-9]+", "-", strength) + "--" + case


def run_one(exe, plugin, work, quantum, strength, case):
    tag = tag_of(strength, case)
    args = [f"{p}={v}" for p, v in zip(PORTS, STRENGTHS[strength])]
    for _ in range(2):
        p = subprocess.run([exe, plugin, "deep_filter_mono", os.path.join(work, f"in-{case}.f32"),
                            os.path.join(work, f"out-{tag}.f32"), str(quantum)] + args,
                           stderr=subprocess.PIPE, text=True)
        drops = [l for l in p.stderr.splitlines() if "dropouts" in l]
        if p.returncode != 0 or not drops:
            sys.exit(f"measure: dfhost failed on {tag}:\n{p.stderr}")
        n = int(drops[-1].split()[-1])
        if n == 0:
            break
    print(f"  {strength} {case}: {n} dropouts", flush=True)
    return tag, n


def delay_of(out, ref):
    # The plugin's delay, by cross-correlation over the speech: 80.7 ms
    # (3872 samples) in every run on 2026-11-19.
    a, b = out[LEAD:], ref[LEAD:]
    n = 1 << int(np.ceil(np.log2(len(a) + len(b))))
    c = np.fft.irfft(np.fft.rfft(a, n) * np.conj(np.fft.rfft(b, n)), n)
    lags = np.arange(0, int(0.5 * RATE))
    return int(lags[np.argmax(c[lags])])


def analyse(work, case, tag, gain):
    out = np.fromfile(os.path.join(work, f"out-{tag}.f32"), np.float32).astype(np.float64) * 10 ** (-gain / 20)
    speech = np.fromfile(os.path.join(work, f"speech-{case}.f32"), np.float32).astype(np.float64)
    noisy = np.fromfile(os.path.join(work, f"in-{case}.f32"), np.float32).astype(np.float64) * 10 ** (-gain / 20)
    d = delay_of(out, speech)
    o = out[d:]
    sp = speech[: len(o)]
    fs, fo = (frames(sp[LEAD:]) ** 2).mean(axis=1), (frames(o[LEAD:]) ** 2).mean(axis=1)
    m = min(len(fs), len(fo))
    fs, fo = fs[:m], fo[:m]
    act = db(fs) > db(fs.max()) - 30
    # What is kept: the speech energy over the frames that hold speech; what
    # is lost: the share of those cut by more than 20 dB, which is what a lost
    # syllable looks like; and the noise, over the lead, out against in.
    kept = float(db(fo[act].sum()) - db(fs[act].sum()))
    lost = float(np.mean(db(fo[act]) < db(fs[act]) - 20))
    depth = float(db((o[int(0.5 * RATE):LEAD - d] ** 2).mean()) - db((noisy[int(0.5 * RATE):LEAD] ** 2).mean()))
    return {"kept_db": round(kept, 2), "lost": round(lost, 3), "noise_db": round(depth, 1), "delay": d}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("set", choices=list(sets()))
    ap.add_argument("--plugin", default="/usr/lib/ladspa/libdeep_filter_ladspa.so")
    ap.add_argument("--work", default=os.path.join(tempfile.gettempdir(), "jayos-audio-measure"))
    ap.add_argument("--jobs", type=int, default=2)
    ap.add_argument("--cases", default="")
    ap.add_argument("--quantum", type=int, default=1024)
    ap.add_argument("--assets", default="")
    # The suite's own: the hashes its made clips have, as JSON.
    ap.add_argument("--pins", default="", help=argparse.SUPPRESS)
    a = ap.parse_args()
    if not os.path.exists(a.plugin):
        sys.exit(f"measure: no plugin at {a.plugin}: install jayos-audio, or give --plugin")
    strengths, cases = sets()[a.set]
    if a.cases:
        want = set(a.cases.split(","))
        cases = [c for c in cases if c[0] in want]
        if not cases:
            sys.exit(f"measure: no case of {a.set} is named {a.cases}")
    pins = {k: tuple(v) for k, v in json.load(open(a.pins)).items()} if a.pins else ASSETS
    os.makedirs(a.work, exist_ok=True)
    clips = assets(a.work, a.assets, pins)
    exe = host(a.work)
    prepare(a.work, clips, cases)
    print(f"{a.set}: {len(strengths)} strengths over {len(cases)} cases, {a.jobs} at a time", flush=True)
    jobs = [(s, c[0]) for s in strengths for c in cases]
    with ThreadPoolExecutor(max_workers=max(1, a.jobs)) as pool:
        done = list(pool.map(lambda j: run_one(exe, a.plugin, a.work, a.quantum, *j), jobs))
    rows = {}
    for (strength, case), (tag, drops) in zip(jobs, done):
        gain = next(c[4] for c in cases if c[0] == case)
        rows[tag] = dict(analyse(a.work, case, tag, gain), strength=strength, case=case, dropouts=drops)
    json.dump(rows, open(os.path.join(a.work, f"{a.set}.json"), "w"), indent=1)
    print("\nspeech kept, dB (share of speech frames cut by more than 20 dB) [noise alone, dB]")
    print(f"{'':16}" + "".join(f"{s:>24}" for s in strengths))
    for case in [c[0] for c in cases]:
        line = f"{case:16}"
        for s in strengths:
            r = rows[tag_of(s, case)]
            line += f"{r['kept_db']:8.1f} ({r['lost'] * 100:4.0f}%) [{r['noise_db']:5.0f}]" + ("!" if r["dropouts"] else " ")
        print(line)
    delays = sorted({r["delay"] for r in rows.values()})
    drops = sum(r["dropouts"] for r in rows.values())
    print(f"delay {delays[0]}" + (f" to {delays[-1]}" if len(delays) > 1 else "") + f" samples; {drops} dropouts")
    print(f"rows in {os.path.join(a.work, a.set + '.json')}")
    return 1 if drops else 0


if __name__ == "__main__":
    sys.exit(main())
