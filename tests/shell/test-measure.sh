#!/usr/bin/env bash
#
# tools/measure/: the paced LADSPA host and the measurement docs/DEEPFILTERNET.md
# publishes, run against tests/shell/measure/stub-plugin.c, a plugin with
# deep_filter_mono's ports that passes its input through a fixed delay.
#
#   tests/shell/test-measure.sh
#
# What a pass-through must give is known exactly: every speech frame kept at
# 0 dB, none cut, no noise removed, and the delay found to the sample. So a
# host that set the wrong control, ran faster than real time, miscounted a
# dropout, or an analysis that aligned, scaled or undid a gain wrongly, is
# caught here without the model, which only a package build has. The clips the
# tables were measured on are refused unless their sha256 is the pinned one;
# here the suite makes its own and hands the script their hashes.
#
# Exit 0 clean, 1 a failure, 2 when it could not run: no C compiler, or no
# python3 with numpy.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOST_C="$ROOT/tools/measure/dfhost.c"
MEASURE="$ROOT/tools/measure/measure.py"
STUB_C="$ROOT/tests/shell/measure/stub-plugin.c"
for f in "$HOST_C" "$MEASURE" "$STUB_C"; do
    [[ -r "$f" ]] || { echo "cannot read ${f#"$ROOT"/}" >&2; exit 2; }
done
CC="${CC:-$(command -v cc || command -v gcc || true)}"
[[ -n "$CC" ]] || { echo "no C compiler: nothing was examined" >&2; exit 2; }
python3 -I -c 'import numpy' 2>/dev/null || { echo "no python3 with numpy: nothing was examined" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/jayos-audio-measure.XXXXXX")" \
    || { echo "no temporary directory" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
SKIP=0
pass() { PASS=$((PASS + 1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \033[31mfail\033[0m %s\n' "$1"; }
check() { # check <description> <expected> <actual>
    if [[ "$2" == "$3" ]]; then pass "$1"; else
        bad "$1"
        printf '         expected: %s\n' "$2"
        printf '         actual:   %s\n' "$3"
    fi
}

echo "the host"
"$CC" -O2 -o "$WORK/dfhost" "$HOST_C" -ldl 2>"$WORK/cc.log" || { bad "dfhost builds"; sed 's/^/         | /' "$WORK/cc.log"; }
"$CC" -O2 -shared -fPIC -o "$WORK/stub.so" "$STUB_C" 2>>"$WORK/cc.log" || bad "the stub plugin builds"
[[ -x "$WORK/dfhost" && -r "$WORK/stub.so" ]] || { echo "nothing to run"; exit 1; }

# Three seconds of noise at a level well off zero, so a dropout is only what
# the plugin writes.
python3 -I -c 'import numpy as np, sys; r = np.random.default_rng(3); (0.1 + 0.05 * r.random(144000)).astype(np.float32).tofile(sys.argv[1])' "$WORK/in.f32"
start=$(date +%s%N)
"$WORK/dfhost" "$WORK/stub.so" deep_filter_mono "$WORK/in.f32" "$WORK/out.f32" 1024 \
    "Attenuation Limit (dB)=70" "Post Filter Beta=0.02" 2> "$WORK/host.log"; rc=$?
ms=$(( ($(date +%s%N) - start) / 1000000 ))
check "it runs the plugin over the file and says its controls: the two given, the other four at their lower bound" \
    "0|Attenuation Limit (dB) = 70|Min processing threshold (dB) = -15|Max ERB processing threshold (dB) = -15|Max DF processing threshold (dB) = -15|Min Processing Buffer (frames) = 0|Post Filter Beta = 0.02|dropouts 0" \
    "$rc|$(sed 's/^ *//' "$WORK/host.log" | paste -sd'|')"
check "  and what comes out is what went in, the plugin's delay later" "0.0" \
    "$(python3 -I -c 'import numpy as np, sys; a = np.fromfile(sys.argv[1], np.float32); b = np.fromfile(sys.argv[2], np.float32); print(abs(b[3872:] - a[:len(a) - 3872]).max().round(6))' "$WORK/in.f32" "$WORK/out.f32")"
# Paced: three seconds of audio take about three seconds, never a burst.
if (( ms >= 2700 )); then pass "  one quantum per real-time period: three seconds of audio took ${ms} ms"
else bad "  one quantum per real-time period: three seconds of audio took ${ms} ms"; fi
STUB_GAP=1 "$WORK/dfhost" "$WORK/stub.so" deep_filter_mono "$WORK/in.f32" "$WORK/out.f32" 1024 2> "$WORK/gap.log"
check "  a run of silence the plugin writes is counted as a dropout" "dropouts 1" "$(sed -n 's/^ *\(dropouts .*\)$/\1/p' "$WORK/gap.log")"
"$WORK/dfhost" "$WORK/stub.so" no_such_label "$WORK/in.f32" "$WORK/out.f32" 1024 2> "$WORK/label.log"; rc=$?
check "  and a label the plugin does not have is refused" "2|no label no_such_label" "$rc|$(cat "$WORK/label.log")"

echo "the measurement"
# Clips of the published ones' shape -- speech in syllables, stereo noise --
# made short, so a run is four seconds, and pinned by their own hashes.
mkdir -p "$WORK/clips"
python3 -I - "$WORK/clips" <<'PYEND'
import json, os, sys, wave, hashlib
import numpy as np
d = sys.argv[1]
r = np.random.default_rng(7)
t = np.arange(2 * 48000) / 48000
speech = 0.3 * np.sin(2 * np.pi * 220 * t) * (np.sin(2 * np.pi * 3 * t) > 0)
noise = 0.2 * r.standard_normal((4 * 48000, 2))
def write(name, x, ch):
    w = wave.open(os.path.join(d, name), "wb"); w.setnchannels(ch); w.setsampwidth(2); w.setframerate(48000)
    w.writeframes((np.clip(x, -1, 1) * 32767).astype("<i2").tobytes()); w.close()
write("clean_freesound_33711.wav", speech, 1)
write("noise_freesound_2530.wav", noise, 2)
pins = {k: [n, hashlib.sha256(open(os.path.join(d, n), "rb").read()).hexdigest()]
        for k, n in (("speech", "clean_freesound_33711.wav"), ("noise", "noise_freesound_2530.wav"))}
json.dump(pins, open(os.path.join(d, "pins.json"), "w"))
PYEND
measure() { python3 -I "$MEASURE" "$@" --plugin "$WORK/stub.so" --assets "$WORK/clips" --pins "$WORK/clips/pins.json" --jobs 3; }
measure levels --work "$WORK/levels" --cases s44n50 > "$WORK/levels.log" 2>&1; rc=$?
cat > "$WORK/row.py" <<'PYEND'
import json, sys
r = json.load(open(sys.argv[1]))
print(" ".join(f"{v['strength']}:{v['kept_db']:.1f}:{v['lost']:.0f}:{v['noise_db']:.0f}:{v['delay']}:{v['dropouts']}" for v in r.values()))
PYEND
row() { python3 -I "$WORK/row.py" "$1"; }
# What is kept is the output's energy over the speech frames against the
# speech's, so the noise a pass-through leaves counts in it: at 6 dB SNR that
# is 10 log10(1 + 10^-0.6), 0.97 dB, and at 37 dB nothing that rounds. The
# real plugin takes the noise 24 to 56 dB down, so in the tables it is gone.
check "levels over a pass-through: each strength keeps every frame, the noise left counted, removes none, at the plugin's delay" \
    "0|gentle:1.0:0:0:3872:0 balanced:1.0:0:0:3872:0 maximum:1.0:0:0:3872:0" "$rc|$(row "$WORK/levels/levels.json" 2>&1)"
check "  and prints the table, with the delay and no dropout" "1|1" \
    "$(grep -cE '^s44n50 +1\.0 \( +0%\) \[ +0\] +1\.0' "$WORK/levels.log")|$(grep -c '^delay 3872 samples; 0 dropouts$' "$WORK/levels.log")"
measure gain --work "$WORK/gain" --cases s44n50g12,s3n40g30 > "$WORK/gain.log" 2>&1; rc=$?
check "gain: 12 and 30 dB before a pass-through, taken off after, give what no gain gives" \
    "0|balanced:1.0:0:0:3872:0 balanced:0.0:0:0:3872:0 maximum:1.0:0:0:3872:0 maximum:0.0:0:0:3872:0" \
    "$rc|$(row "$WORK/gain/gain.json" 2>&1)"
# The noise alone, over the lead, at the case's -50 dBFS and 12 dB more.
check "  and the plugin is handed the gain: the lead's noise at -50 + 12 dBFS" "-38" \
    "$(python3 -I -c 'import numpy as np, sys; x = np.fromfile(sys.argv[1], np.float32).astype(float)[:96000]; print(round(10 * np.log10((x ** 2).mean())))' "$WORK/gain/in-s44n50g12.f32")"

echo "the clips"
python3 -I -c 'import json, sys; p = json.load(open(sys.argv[1])); p["speech"][1] = "0" * 64; json.dump(p, open(sys.argv[2], "w"))' "$WORK/clips/pins.json" "$WORK/badpins.json"
out=$(python3 -I "$MEASURE" levels --plugin "$WORK/stub.so" --assets "$WORK/clips" --pins "$WORK/badpins.json" --work "$WORK/bad" 2>&1); rc=$?
check "a clip that does not hash to its pin is refused, by name, before anything runs" "1|1|0" \
    "$rc|$(grep -c '^measure: clean_freesound_33711.wav hashes to [0-9a-f]\{64\}, not the 0\{64\}' <<< "$out")|$(ls "$WORK/bad" 2>/dev/null | grep -c '^in-')"
check "  and the script pins the two the tables were measured on" "2" \
    "$(grep -cE '^    "(speech|noise)": \("(clean_freesound_33711|noise_freesound_2530)\.wav", "(2d885e9f45c0f9381aee09a397ecd160aff1875ffb75ebe2217d21c3511b0d5d|cc774d58170fc5b8f143345ef8ff31583feef71f23f447336fdd56c8478d8a8a)"\),$' "$MEASURE")"
check "  fetched from the fork at the commit the recipe pins" "1|1" \
    "$(grep -c '^FORK = "https://raw.githubusercontent.com/ismailivanov/DeepFilterNetPlus"$' "$MEASURE")|$(grep -cF 'url = f"{FORK}/{pinned_commit()}/assets/{name}"' "$MEASURE")"
out=$(python3 -I "$MEASURE" levels --plugin "$WORK/none.so" --work "$WORK/none" 2>&1); rc=$?
check "no plugin is said, with what to do" "1|1" "$rc|$(grep -c 'no plugin at .*none.so: install jayos-audio, or give --plugin' <<< "$out")"
out=$(measure levels --work "$WORK/nocase" --cases s1n2 2>&1); rc=$?
check "and a case the set does not have is refused" "1|1" "$rc|$(grep -c '^measure: no case of levels is named s1n2$' <<< "$out")"

echo
skipped=""
(( SKIP > 0 )) && skipped=", $SKIP not exercised"
printf '%d passed, %d failed%s\n' "$PASS" "$FAIL" "$skipped"
(( FAIL == 0 ))
