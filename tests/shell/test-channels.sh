#!/usr/bin/env bash
#
# The channel sink: balance, mono and left/right swap (`jayos-audio channels`).
#
#   tests/shell/test-channels.sh
#
# Exit 0: every case that ran passed, the box a counted skip where PipeWire's
# tools are not installed. 1: a case failed. 2: could not run -- no jq, or a
# file it reads is missing.
#
# WHAT THIS PROVES
#
# Against stand-ins for systemd's user manager and PipeWire's tools: the four
# mixer gains for every combination of the three; the host's configuration;
# that `status` prints the contract's keys; that `set` refuses a bad word
# before it writes anything, starts the host and makes the sink the default
# with any adjustment on, sets a running sink's gains live, and stops the host
# and gives the default back to the device with none on -- stopping first, so
# that its watcher cannot take the default again; that `output` moves the
# playback side; and that the watcher follows a device a person chooses and
# undoes anything else's move of the playback side.
#
# Then under a real PipeWire and WirePlumber, in a box of their own with two
# stand-in devices: a tone played into the default output comes out of the
# device as each adjustment says it should, set live; a device chosen while it
# runs is moved onto, and the sink is the default again; a move of the
# playback side into another device is undone; and with nothing on, the host
# stops and the device is the default again.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENGINE="$ROOT/src/jayos-audio"
CONTRACT="$ROOT/contract"

command -v jq >/dev/null 2>&1 || { echo "test-channels not exercised: jq is not installed" >&2; exit 2; }
for f in "$ENGINE" "$CONTRACT/channels-status-keys.txt" "$CONTRACT/config.channels.conf" \
         "$ROOT/systemd/jayos-audio-channels.service"; do
    [[ -r "$f" ]] || { echo "cannot read ${f#"$ROOT"/}" >&2; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/jayos-audio-channels.XXXXXX")" || exit 2
RUNLINK=""
trap 'rm -rf "$WORK"; [[ -n "$RUNLINK" ]] && rm -f "$RUNLINK"' EXIT

PASS=0
FAIL=0
SKIP=0
pass() { PASS=$((PASS + 1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \033[31mfail\033[0m %s\n' "$1"; }
skip() { printf '  skip %s\n' "$1"; SKIP=$((SKIP + 1)); }
check() { # check <what> <expected> <actual>
    if [[ "$2" == "$3" ]]; then pass "$1"; else
        bad "$1"
        printf '         expected: %s\n' "$2"
        printf '         actual:   %s\n' "$3"
    fi
}
says() { if grep -qF -- "$2" <<< "$3"; then pass "$1"; else
             bad "$1"; printf '         wanted: %s\n' "$2"
             printf '%s\n' "$3" | sed 's/^/         got:    /'; fi; }
finish() {
    echo
    local skipped=""
    (( SKIP > 0 )) && skipped=", $SKIP not exercised"
    printf '%d passed, %d failed%s\n' "$PASS" "$FAIL" "$skipped"
    (( FAIL == 0 ))
    exit $?
}

# ── the stand-ins ────────────────────────────────────────────────────────────
#
# $ST holds the machine: ch-active and ch-enabled for the unit, nodes for what
# pw-dump lists ("id node.name media.class" per line), meta.<key> for the
# default metadata, moves for target.object set on a node, monitor for what
# `pw-metadata -m` prints, calls for every call made.
BIN="$WORK/bin"
ST="$WORK/st"
mkdir -p "$BIN" "$ST"
export ST

cat > "$BIN/systemctl" <<'STUB'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "$ST/calls"
up()   { [[ -e "$ST/no-sink" ]] && return 0
         grep -q ' jayos_channels_sink ' "$ST/nodes" 2>/dev/null && return 0
         printf '81 jayos_channels_sink Audio/Sink\n82 jayos_channels_output Stream/Output/Audio\n' >> "$ST/nodes"; }
down() { [[ -f "$ST/nodes" ]] && sed -i '/ jayos_channels_/d' "$ST/nodes"; }
case " $* " in
    *" is-active "*)        [[ -e "$ST/ch-active" ]] ;;
    *" is-enabled "*)       [[ -e "$ST/ch-enabled" ]] ;;
    *" enable --now "*)     touch "$ST/ch-enabled" "$ST/ch-active"; up ;;
    *" enable "*)           touch "$ST/ch-enabled" ;;
    *" restart "*)          touch "$ST/ch-active"; down; up ;;
    *" disable --now "*)    [[ -e "$ST/no-stop" ]] && exit 1
                            rm -f "$ST/ch-enabled" "$ST/ch-active"; down ;;
    *)                      exit 1 ;;
esac
STUB
cat > "$BIN/pw-dump" <<'STUB'
#!/usr/bin/env bash
[[ -f "$ST/nodes" ]] || { echo '[]'; exit 0; }
jq -Rn '[inputs | split(" ") | {id: (.[0] | tonumber), type: "PipeWire:Interface:Node",
         info: {props: {"node.name": .[1], "media.class": .[2]}}}]' < "$ST/nodes"
STUB
cat > "$BIN/pw-metadata" <<'STUB'
#!/usr/bin/env bash
printf 'pw-metadata %s\n' "$*" >> "$ST/calls"
if [[ "$1" == -n && "$3" == -m ]]; then
    cat "$ST/monitor" 2>/dev/null
    exit 0
fi
if [[ "$1" == -n ]]; then
    shift 3
    case $# in
        1) [[ -f "$ST/meta.$1" ]] && printf "update: id:0 key:'%s' value:'%s' type:'Spa:String:JSON'\n" "$1" "$(cat "$ST/meta.$1")" ;;
        2) [[ "$1" == -d ]] && rm -f "$ST/meta.$2" ;;
        *) printf '%s' "$2" > "$ST/meta.$1" ;;
    esac
    exit 0
fi
printf '%s %s %s\n' "$1" "$2" "$3" >> "$ST/moves"
STUB
cat > "$BIN/pw-cli" <<'STUB'
#!/usr/bin/env bash
printf 'pw-cli %s\n' "$*" >> "$ST/calls"
[[ -e "$ST/pwcli-fail" ]] && exit 1
exit 0
STUB
# The host's exec: records its arguments, then stays until the watcher it
# was started beside -- now its child -- has read everything and gone.
cat > "$BIN/pipewire" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$ST/pipewire.args"
for _ in $(seq 100); do
    pgrep -P $$ >/dev/null 2>&1 || exit 0
    sleep 0.05
done
STUB
chmod +x "$BIN"/*

MODULES="$WORK/pw-modules"
mkdir -p "$MODULES"
: > "$MODULES/libpipewire-module-filter-chain.so"

H="$WORK/home"
STATE="$H/.local/state/jayos-audio/channels.state"
fresh() {
    rm -rf "$H" "$ST" "$WORK/run"
    mkdir -p "$H" "$ST" "$WORK/run"
}
engine() { # engine <args...>: OUT and RC, with the stand-ins first on PATH
    OUT=$(env HOME="$H" XDG_STATE_HOME="$H/.local/state" XDG_RUNTIME_DIR="$WORK/run" \
              JAYOS_AUDIO_PW_MODULES="${MODULES_OVERRIDE-$MODULES}" JAYOS_AUDIO_WAIT=1 \
              PATH="$BIN:$PATH" bash "$ENGINE" "$@" 2>&1)
    RC=$?
}
meta() { cat "$ST/meta.$1" 2>/dev/null; }
calls() { if [[ -f "$ST/calls" ]]; then grep -c -- "$1" "$ST/calls"; else echo 0; fi; }
chose() { printf '{ "name": "%s" }' "$1" > "$ST/meta.default.configured.audio.sink"; }
state() { mkdir -p "${STATE%/*}"; printf '%s\n' "$@" > "$STATE"; }
gains() { # gains <conf text>: "L1 L2 R1 R2" as the two mixers carry them
    sed -n -E 's/.*name = ([lr]) label = mixer control = \{ "Gain 1" = ([0-9.]+) "Gain 2" = ([0-9.]+) \}.*/\2 \3/p' <<<"$1" \
        | tr '\n' ' ' | sed 's/ $//'
}

# ── the gains ────────────────────────────────────────────────────────────────
echo "the gains, for every combination"
while IFS='|' read -r mono swap balance want what; do
    [[ -n "$mono" ]] || continue
    fresh
    state "mono=$mono" "swap=$swap" "balance=$balance"
    engine channels config
    check "$what" "$want" "$(gains "$OUT")"
done <<'TABLE'
off|off|0|1.0000 0.0000 0.0000 1.0000|nothing on: each side its own
on|off|0|0.5000 0.5000 0.5000 0.5000|mono: each side the mean of both
off|on|0|0.0000 1.0000 1.0000 0.0000|swap: each side the other's
on|on|0|0.5000 0.5000 0.5000 0.5000|mono and swap: mono, which swap cannot change
off|off|-50|1.0000 0.0000 0.0000 0.5000|balance -50: the right at half
off|off|100|0.0000 0.0000 0.0000 1.0000|balance 100: the left silent
off|off|-100|1.0000 0.0000 0.0000 0.0000|balance -100: the right silent
on|off|-40|0.5000 0.5000 0.3000 0.3000|mono with balance -40: the right side's mean at 0.6
off|on|25|0.0000 0.7500 1.0000 0.0000|swap with balance 25: the left, now the right's, at 0.75
TABLE
fresh
state "balance=+025"
engine channels config
check "a balance written +025 is 25: the left at 0.75" "0.7500 0.0000 0.0000 1.0000" "$(gains "$OUT")"
state "balance=1.5"
engine channels config
check "a balance that is not a whole number is read as 0" "1.0000 0.0000 0.0000 1.0000" "$(gains "$OUT")"
state "balance=-101"
engine channels config
check "and one past -100 too" "1.0000 0.0000 0.0000 1.0000" "$(gains "$OUT")"
# A locale whose decimal separator is a comma: mawk prints 0,5000 under one
# (RUN), and PipeWire's parser reads that as two values. One installed, or
# one localedef builds from its sources into the scratch directory.
COMMA=$(locale -a 2>/dev/null | grep -m1 -iE '^(de_DE|fr_FR|it_IT|es_ES|nl_NL|ru_RU)\.utf-?8$')
LOCDIR=""
if [[ -z "$COMMA" ]] && command -v localedef >/dev/null 2>&1 && mkdir -p "$WORK/locale" \
   && localedef -i de_DE -f UTF-8 "$WORK/locale/de_DE.UTF-8" >/dev/null 2>&1; then
    COMMA=de_DE.UTF-8 LOCDIR="$WORK/locale"
fi
if [[ -n "$COMMA" ]]; then
    state "balance=-50"
    LOCPATH="${LOCDIR:-${LOCPATH:-}}" LC_ALL=$COMMA engine channels config
    check "a locale with a decimal comma ($COMMA) writes the gains with a point" "1.0000 0.0000 0.0000 0.5000" "$(gains "$OUT")"
else
    skip "the gains under a decimal-comma locale not exercised: none is installed, and localedef could not build one"
fi

# ── the configuration ────────────────────────────────────────────────────────
echo
echo "the host's configuration"
fresh
engine channels config
check "with nothing set and no device chosen, the contract's, byte for byte" \
    "$(grep -v '^# Generated by jayos-audio' "$CONTRACT/config.channels.conf")" \
    "$(grep -v '^# Generated by jayos-audio' <<<"$OUT")"
says "the sink, by its name" 'node.name   = "jayos_channels_sink"' "$OUT"
says "a sink" 'media.class = Audio/Sink' "$OUT"
says "stereo" 'audio.position = [ FL FR ]' "$OUT"
says "the playback side passive, under its name" 'node.name    = "jayos_channels_output"' "$OUT"
says "each input fed to both mixers" '{ output = "inL:Out" input = "r:In 1" }' "$OUT"
says "real time from rtkit, not the portal" "args = { rtportal.enabled = false }" "$OUT"
check "no device named while none is chosen" 0 "$(grep -c 'target.object' <<<"$OUT")"
state "output=alsa_output.speakers"
engine channels config
says "a chosen device is played on by name" 'target.object = "alsa_output.speakers"' "$OUT"

# ── status ───────────────────────────────────────────────────────────────────
echo
echo "status"
fresh
engine channels status
check "status prints the contract's keys, in its order" \
    "$(grep -v '^#' "$CONTRACT/channels-status-keys.txt" | tr '\n' ' ')" "$(jq -r 'keys_unsorted[]' <<<"$OUT" | tr '\n' ' ')"
check "nothing set: installed, nothing on, nothing running" "true false false false false 0" \
    "$(jq -r '[.installed, .active, .mono, .swap, .running, .balance] | map(tostring) | join(" ")' <<<"$OUT")"
MODULES_OVERRIDE="$WORK/none" engine channels status
check "no filter-chain module: not installed" "false" "$(jq -r '.installed' <<<"$OUT")"
state "mono=on" "balance=-30" "output=alsa_output.speakers"
touch "$ST/ch-active"; printf '81 jayos_channels_sink Audio/Sink\n' > "$ST/nodes"
engine channels status
check "set and running, another default: active, not loaded" "true true -30 alsa_output.speakers false false" \
    "$(jq -r '[.active, .mono, .balance, .output, .isDefault, .loaded] | map(tostring) | join(" ")' <<<"$OUT")"
printf '{ "name": "jayos_channels_sink" }' > "$ST/meta.default.audio.sink"
engine channels status
check "and the default: loaded" "true true" "$(jq -r '[.isDefault, .loaded] | map(tostring) | join(" ")' <<<"$OUT")"

# ── set: refused ─────────────────────────────────────────────────────────────
echo
echo "set, refused"
for words in "mono=yes" "swap=" "balance=101" "balance=1.5" "balance=abc" "balance=" "volume=3" "mono" "mono=on balance=x"; do
    fresh
    state "swap=on" "output=alsa_output.speakers"
    before=$(cat "$STATE")
    # shellcheck disable=SC2086
    engine channels set $words
    check "'$words' is refused, and nothing is written or started" "1|$before|0" \
        "$RC|$(cat "$STATE")|$(calls systemctl)"
done
fresh
engine channels set
check "no word at all is refused with the usage" "1" "$RC"
says "naming the three" "mono=on|off] [swap=on|off] [balance=<-100..100>]" "$OUT"

# ── set: on ──────────────────────────────────────────────────────────────────
echo
echo "set, on"
fresh
chose alsa_output.speakers
engine channels set mono=on
check "mono on exits 0" 0 "$RC"
check "it records mono and the device that was the default" "mono=on|output=alsa_output.speakers" \
    "$(grep '^mono=' "$STATE")|$(grep '^output=' "$STATE")"
check "the unit is enabled and started in one call" 1 "$(calls 'systemctl --user enable --now jayos-audio-channels.service')"
check "the sink is the default output" '{ "name": "jayos_channels_sink" }' "$(meta default.configured.audio.sink)"
says "and it says so" "sound adjustments on (mono on, swap off, balance 0), playing on alsa_output.speakers" "$OUT"

# Running on the same device: the gains live, no restart.
: > "$ST/calls"
engine channels set swap=on balance=-020
check "a change while it runs on the same device exits 0" 0 "$RC"
check "with the gains set live, mono's still, the right at 0.8" 1 \
    "$(calls 'pw-cli set-param 81 Props { params = \[ "l:Gain 1" 0.5000 "l:Gain 2" 0.5000 "r:Gain 1" 0.4000 "r:Gain 2" 0.4000 \] }')"
check "and no restart" 0 "$(calls 'systemctl --user restart')"
check "balance kept as a plain number" "balance=-20" "$(grep '^balance=' "$STATE")"
touch "$ST/pwcli-fail"; : > "$ST/calls"
engine channels set mono=off
check "where PipeWire refuses the live change, the host restarts" "0|1" \
    "$RC|$(calls 'systemctl --user restart jayos-audio-channels.service')"
rm -f "$ST/pwcli-fail"

# The sink is the default now, so the device is the one recorded.
: > "$ST/calls"
engine channels set balance=10
says "with the sink the default, it keeps playing on the device recorded" "playing on alsa_output.speakers" "$OUT"

# A device chosen while it was off is the one it starts on.
fresh
state "output=alsa_output.speakers"
chose alsa_output.headphones
engine channels set balance=50
check "the device chosen since is the one it plays on" "output=alsa_output.headphones" "$(grep '^output=' "$STATE")"

# No device at all, and EasyEffects' sink is not one.
fresh
printf '{ "name": "easyeffects_sink" }' > "$ST/meta.default.configured.audio.sink"
printf '{ "name": "easyeffects_sink" }' > "$ST/meta.default.audio.sink"
engine channels set mono=on
check "with no device to play on it is refused, and nothing started" "1|0" \
    "$RC|$(calls 'enable --now')"
says "saying so" "there is no output device to play the adjusted sound on" "$OUT"
fresh
chose alsa_output.speakers
MODULES_OVERRIDE="$WORK/none" engine channels set mono=on
check "with no filter-chain module it is refused" "1|0" "$RC|$(calls 'enable --now')"
fresh
chose alsa_output.speakers
touch "$ST/no-sink"
engine channels set mono=on
check "a sink that never appears is a failure naming the journal" 1 "$RC"
says "with the journal to read" "journalctl --user -u jayos-audio-channels.service" "$OUT"

# ── set: off ─────────────────────────────────────────────────────────────────
echo
echo "set, off"
fresh
chose alsa_output.speakers
engine channels set swap=on
: > "$ST/calls"
engine channels set swap=off
check "the last adjustment off exits 0" 0 "$RC"
check "the unit is stopped and disabled" 1 "$(calls 'systemctl --user disable --now jayos-audio-channels.service')"
check "the device it played on is the default again" '{ "name": "alsa_output.speakers" }' "$(meta default.configured.audio.sink)"
check "stopped before the default is given back, so its watcher cannot take it again" "systemctl pw-metadata" \
    "$(grep -E 'disable --now|default.configured.audio.sink \{' "$ST/calls" | cut -d' ' -f1 | tr '\n' ' ' | sed 's/ $//')"
says "and it says so" "sound adjustments off (mono off, swap off, balance 0), playing on alsa_output.speakers" "$OUT"
fresh
state "mono=on" "output=alsa_output.speakers"
chose alsa_output.headphones
engine channels set mono=off
check "a default somebody else chose is left as it is" '{ "name": "alsa_output.headphones" }' "$(meta default.configured.audio.sink)"
fresh
state "mono=on"
printf '{ "name": "jayos_channels_sink" }' > "$ST/meta.default.configured.audio.sink"
engine channels set mono=off
check "with no device recorded, the sink's default is cleared for WirePlumber to choose" "" "$(meta default.configured.audio.sink)"
fresh
state "mono=on" "output=alsa_output.speakers"
touch "$ST/ch-active" "$ST/no-stop"
engine channels set mono=off
check "a unit that will not stop is a failure" 1 "$RC"

# ── output ───────────────────────────────────────────────────────────────────
echo
echo "output"
fresh
state "mono=on" "output=alsa_output.speakers"
engine channels output
check "with no device, it prints the one recorded" "alsa_output.speakers" "$OUT"
touch "$ST/ch-active"; printf '81 jayos_channels_sink Audio/Sink\n82 jayos_channels_output Stream/Output/Audio\n' > "$ST/nodes"
engine channels output alsa_output.headphones
check "a device given while it runs moves the playback side by target.object" "0|82 target.object alsa_output.headphones" \
    "$RC|$(cat "$ST/moves" 2>/dev/null)"
check "and is recorded" "output=alsa_output.headphones" "$(grep '^output=' "$STATE")"
for not in jayos_channels_sink easyeffects_sink alsa_output.speakers.monitor; do
    engine channels output "$not"
    check "$not is refused as a device to play on" 1 "$RC"
done

# ── the host and its watcher ─────────────────────────────────────────────────
echo
echo "the host, and its watcher"
fresh
state "mono=on" "output=alsa_output.headphones"
engine channels host
check "the host runs PipeWire on the configuration it wrote" "-c $WORK/run/jayos-audio/channels.conf" \
    "$(cat "$ST/pipewire.args" 2>/dev/null)"
says "which plays on the device recorded" 'target.object = "alsa_output.headphones"' "$(cat "$WORK/run/jayos-audio/channels.conf")"
check "and its watcher reads the default metadata as it changes" 1 "$(calls 'pw-metadata -n default -m')"

# The watcher, fed a run of changes.
fresh
state "mono=on" "output=alsa_output.speakers"
printf '81 jayos_channels_sink Audio/Sink\n82 jayos_channels_output Stream/Output/Audio\n90 Firefox Stream/Output/Audio\n' > "$ST/nodes"
cat > "$ST/monitor" <<'EOF'
Found "default" metadata 34
update: id:0 key:'default.audio.sink' value:'{"name":"jayos_channels_sink"}' type:'Spa:String:JSON'
update: id:0 key:'default.configured.audio.sink' value:'{ "name": "jayos_channels_sink" }' type:'Spa:String:JSON'
update: id:0 key:'default.configured.audio.sink' value:'{ "name": "easyeffects_sink" }' type:'Spa:String:JSON'
update: id:90 key:'target.object' value:'66' type:'Spa:Id'
update: id:82 key:'target.object' value:'alsa_output.speakers' type:'Spa:Id'
update: id:0 key:'default.configured.audio.sink' value:'{ "name": "alsa_output.headphones" }' type:'Spa:String:JSON'
update: id:82 key:'target.object' value:'alsa_output.headphones' type:'(null)'
update: id:82 key:'target.object' value:'66' type:'Spa:Id'
EOF
engine channels host
check "a device a person chooses is moved onto, and anything else's move of the playback side undone" \
    "82 target.object alsa_output.headphones|82 target.object alsa_output.headphones" \
    "$(paste -sd'|' "$ST/moves" 2>/dev/null)"
check "the device chosen is recorded" "output=alsa_output.headphones" "$(grep '^output=' "$STATE")"
check "and the sink is the default again" '{ "name": "jayos_channels_sink" }' "$(meta default.configured.audio.sink)"
check "the sink chosen, EasyEffects' sink chosen, another stream moved and its own moves change nothing else" 1 \
    "$(grep -c 'default.configured.audio.sink {' "$ST/calls")"

# ── the unit ─────────────────────────────────────────────────────────────────
echo
echo "the unit"
UNITF="$ROOT/systemd/jayos-audio-channels.service"
check "it runs the channel host where the package installs the engine" \
    "/usr/lib/jayos-audio/jayos-audio channels host" "$(sed -n 's/^ExecStart=//p' "$UNITF")"
check "and goes with PipeWire, as the noise suppression's does" "PartOf=pipewire.service" "$(grep -x 'PartOf=pipewire.service' "$UNITF")"
check "the package installs it beside the noise suppression's" 1 \
    "$(grep -c 'systemd/jayos-audio-channels.service" -t "$pkgdir/usr/lib/systemd/user/"' "$ROOT/packaging/steps.sh")"

# ── under a real PipeWire ────────────────────────────────────────────────────
echo
echo "the channel sink, under a real PipeWire"
need=""
for t in pipewire wireplumber pw-dump pw-metadata pw-cli pw-link pw-cat jq dbus-run-session python3 timeout setsid pgrep; do
    command -v "$t" >/dev/null 2>&1 || need+="$t "
done
if [[ -n "$need" ]]; then
    skip "the channel sink under a real PipeWire not exercised: no ${need% }"
    finish
fi
# A socket's path is at most 107 bytes: the box's runtime directory is
# reached by a short link, as tests/shell/test-host.sh's is.
for base in "${TMPDIR:-/tmp}" /tmp /dev/shm; do
    l="$base/jch.$$"
    if ln -s "$WORK/box/run" "$l" 2>/dev/null; then RUNLINK=$l; break; fi
done
if [[ -z "$RUNLINK" || ${#RUNLINK} -gt 60 ]]; then
    skip "the channel sink under a real PipeWire not exercised: no directory with a path short enough for PipeWire's socket"
    finish
fi
mkdir -p "$WORK/box/run" "$WORK/box/st" "$WORK/boxbin"
# systemd's user manager for one unit: the host, run in the box in a session
# of its own, so that stopping it stops its watcher too, as a unit's control
# group does.
cat > "$WORK/boxbin/systemctl" <<'STUB'
#!/usr/bin/env bash
pidf="$BOX_STATE/host.pid"
alive() { [[ -f "$pidf" ]] && kill -0 "$(cat "$pidf")" 2>/dev/null; }
start() { alive && return 0
          setsid bash "$BOX_ENGINE" channels host > "$BOX_STATE/host.log" 2>&1 &
          echo $! > "$pidf"; }
stop()  { alive && kill -- -"$(cat "$pidf")" 2>/dev/null; rm -f "$pidf"; sleep 0.3; }
case " $* " in
    *" is-active "*)     alive ;;
    *" is-enabled "*)    [[ -e "$BOX_STATE/enabled" ]] ;;
    *" enable --now "*)  touch "$BOX_STATE/enabled"; start ;;
    *" enable "*)        touch "$BOX_STATE/enabled" ;;
    *" restart "*)       stop; start ;;
    *" disable --now "*) rm -f "$BOX_STATE/enabled"; stop ;;
    *)                   exit 1 ;;
esac
STUB
chmod +x "$WORK/boxbin/systemctl"

# Three seconds of a 440 Hz tone at half scale, 48 kHz, 16-bit stereo: in
# the left channel alone, and in both.
python3 -I - "$WORK/left.wav" "$WORK/both.wav" <<'EOF'
import math, struct, sys, wave
for path, right in ((sys.argv[1], 0), (sys.argv[2], 1)):
    w = wave.open(path, "wb"); w.setnchannels(2); w.setsampwidth(2); w.setframerate(48000)
    frames = []
    for i in range(48000 * 3):
        s = int(0.5 * 32767 * math.sin(2 * math.pi * 440 * i / 48000))
        frames.append(struct.pack("<hh", s, s * right))
    w.writeframes(b"".join(frames)); w.close()
EOF

cat > "$WORK/box.sh" <<'BOX'
#!/usr/bin/env bash
# Runs inside dbus-run-session; prints "key value" lines for the suite.
set -u
export XDG_CONFIG_HOME="$BOX/config" XDG_STATE_HOME="$BOX/state" HOME="$BOX/home"
unset PIPEWIRE_REMOTE PIPEWIRE_RUNTIME_DIR PULSE_SERVER
mkdir -p "$XDG_RUNTIME_DIR" "$HOME" "$XDG_STATE_HOME" \
    "$XDG_CONFIG_HOME/wireplumber/wireplumber.conf.d" \
    "$XDG_CONFIG_HOME/wireplumber/main.lua.d" "$XDG_CONFIG_HOME/wireplumber/bluetooth.lua.d"
chmod 700 "$XDG_RUNTIME_DIR"
# Hardware off: 0.5 by its profile, 0.4 by its Lua switches.
printf 'wireplumber.profiles = {\n  main = {\n    hardware.audio = disabled\n    hardware.bluetooth = disabled\n    hardware.video-capture = disabled\n  }\n}\n' \
    > "$XDG_CONFIG_HOME/wireplumber/wireplumber.conf.d/10-box.conf"
echo 'alsa_monitor.enabled = false; v4l2_monitor.enabled = false; libcamera_monitor.enabled = false' \
    > "$XDG_CONFIG_HOME/wireplumber/main.lua.d/90-box.lua"
echo 'bluez_monitor.enabled = false' > "$XDG_CONFIG_HOME/wireplumber/bluetooth.lua.d/90-box.lua"
trap 'bash "$BOX_BIN/systemctl" --user disable --now x >/dev/null 2>&1; kill $(jobs -p) 2>/dev/null; wait 2>/dev/null' EXIT

pipewire > "$BOX/pipewire.log" 2>&1 &
for _ in $(seq 50); do [[ -S "$XDG_RUNTIME_DIR/pipewire-0" ]] && break; sleep 0.1; done
[[ -S "$XDG_RUNTIME_DIR/pipewire-0" ]] || { echo "error no pipewire"; exit 1; }
wireplumber > "$BOX/wireplumber.log" 2>&1 &
sleep 1
for n in speakers headphones; do
    pw-cli create-node adapter "{ factory.name=support.null-audio-sink node.name=$n node.description=$n media.class=Audio/Sink object.linger=true audio.position=[FL FR] }" > /dev/null
done
for _ in $(seq 50); do [[ $(pw-dump 2>/dev/null | grep -c '"headphones"\|"speakers"') -ge 2 ]] && break; sleep 0.1; done
pw-metadata -n default 0 default.configured.audio.sink '{ "name": "speakers" }' Spa:String:JSON > /dev/null

ja() { PATH="$BOX_BIN:$PATH" JAYOS_AUDIO_WAIT=8 bash "$BOX_ENGINE" "$@" 2>&1; }
configured() { pw-metadata -n default 0 default.configured.audio.sink 2>/dev/null | sed -n -E "s/.*value:'(.*)' type.*/\1/p" | jq -r '.name // empty'; }
playing_on() { pw-link -l 2>/dev/null | awk '/^jayos_channels_output:output_FL/ {getline; sub(/.*\|-> /, ""); sub(/:.*/, ""); print; exit}'; }
# levels <device> <wav>: the RMS of each channel the device received while the
# tone played into the default output, "left right".
levels() {
    local out="$BOX/rec.$RANDOM.wav" r
    pw-cat --record --target "$1" -P '{ stream.capture.sink = true }' --rate 48000 --channels 2 --format s16 "$out" > /dev/null 2>&1 &
    r=$!
    sleep 0.5
    pw-cat --playback "$2" > /dev/null 2>&1
    sleep 0.2; kill "$r" 2>/dev/null; wait "$r" 2>/dev/null
    python3 -I - "$out" <<'EOF'
import math, struct, sys, wave
try:
    w = wave.open(sys.argv[1]); n = w.getnframes(); w.setpos(min(n, 24000)); d = w.readframes(n)
    v = struct.unpack("<%dh" % (len(d) // 2), d)
    rms = lambda x: math.sqrt(sum(a * a for a in x) / max(1, len(x)))
    print("%d %d" % (rms(v[0::2]), rms(v[1::2])))
except Exception:
    print("none")
EOF
}

echo "on $(ja channels set mono=on | tail -n 1)"
sleep 1
echo "default-after-on $(configured)"
echo "playing-on $(playing_on)"
echo "mono $(levels speakers "$BOX_LEFT")"
ja channels set mono=off swap=on > /dev/null
sleep 0.5
echo "swap $(levels speakers "$BOX_LEFT")"
echo "swap-pid-kept $(cat "$BOX_STATE/host.pid" 2>/dev/null)"
ja channels set swap=off balance=-50 > /dev/null
sleep 0.5
echo "balance $(levels speakers "$BOX_BOTH")"

echo "host-pid $(cat "$BOX_STATE/host.pid" 2>/dev/null)"
pw-metadata -n default 0 default.configured.audio.sink '{ "name": "headphones" }' Spa:String:JSON > /dev/null
sleep 1.5
echo "default-after-choice $(configured)"
echo "playing-on-after-choice $(playing_on)"
echo "output-after-choice $(ja channels output)"
echo "balance-on-headphones $(levels headphones "$BOX_BOTH")"

own=$(pw-dump 2>/dev/null | jq -r 'first(.[] | select(.type == "PipeWire:Interface:Node" and .info.props["node.name"] == "jayos_channels_output") | .id) // empty')
pw-metadata "$own" target.object speakers > /dev/null
sleep 1.5
echo "playing-on-after-move $(playing_on)"

echo "off $(ja channels set balance=0 | tail -n 1)"
sleep 1
echo "default-after-off $(configured)"
echo "sink-after-off $(pw-dump 2>/dev/null | grep -c '"jayos_channels_sink"')"
BOX
OUT=$(cd "$WORK" && BOX="$WORK/box" XDG_RUNTIME_DIR="$RUNLINK" BOX_BIN="$WORK/boxbin" BOX_STATE="$WORK/box/st" \
      BOX_ENGINE="$ENGINE" BOX_LEFT="$WORK/left.wav" BOX_BOTH="$WORK/both.wav" \
      timeout 120 dbus-run-session -- bash "$WORK/box.sh" 2>/dev/null)
val() { sed -n -E "s/^$1 (.*)$/\\1/p" <<<"$OUT" | head -n 1; }
# within <"left right"> <want left> <want right>: each within 10% of what it
# should be, or under 100 where it should be silent.
within() {
    awk -v got="$1" -v wl="$2" -v wr="$3" 'BEGIN {
        n = split(got, g, " "); if (n != 2) exit 1
        ok = 1
        for (i = 1; i <= 2; i++) { w = (i == 1) ? wl : wr
            if (w == 0) { if (g[i] >= 100) ok = 0 }
            else if (g[i] < w * 0.9 || g[i] > w * 1.1) ok = 0 }
        exit !ok }'
}
if grep -q '^error ' <<<"$OUT" || [[ -z "$OUT" ]]; then
    bad "the box did not come up: $(head -n 3 <<<"$OUT")"
    finish
fi
# The tone at half scale: an RMS of 0.5 / sqrt(2) of full scale.
FULL=11585
HALF=5793
check "mono on exits with its line" "sound adjustments on (mono on, swap off, balance 0), playing on speakers" "$(val on)"
check "the sink is the default output" "jayos_channels_sink" "$(val default-after-on)"
check "and plays on the device that was the default" "speakers" "$(val playing-on)"
if within "$(val mono)" "$HALF" "$HALF"; then pass "mono: a tone in the left alone reaches both sides at half ($(val mono))"
else bad "mono: a tone in the left alone reached the device as '$(val mono)', not $HALF $HALF"; fi
if within "$(val swap)" 0 "$FULL"; then pass "swap, set live: the left's tone comes out on the right alone ($(val swap))"
else bad "swap: the left's tone reached the device as '$(val swap)', not 0 $FULL"; fi
check "set live: the host was not restarted" "$(val swap-pid-kept)" "$(val host-pid)"
if within "$(val balance)" "$FULL" "$HALF"; then pass "balance -50: a tone in both, the right at half ($(val balance))"
else bad "balance -50: the tone reached the device as '$(val balance)', not $FULL $HALF"; fi
check "a device chosen while it runs: the sink is the default again" "jayos_channels_sink" "$(val default-after-choice)"
check "and it plays on the device chosen" "headphones" "$(val playing-on-after-choice)"
check "which is recorded" "headphones" "$(val output-after-choice)"
if within "$(val balance-on-headphones)" "$FULL" "$HALF"; then pass "and the device chosen hears the adjustment ($(val balance-on-headphones))"
else bad "the device chosen heard '$(val balance-on-headphones)', not $FULL $HALF"; fi
check "a move of the playback side by anything else is undone" "headphones" "$(val playing-on-after-move)"
check "nothing on: off exits with its line" "sound adjustments off (mono off, swap off, balance 0), playing on headphones" "$(val off)"
check "the device is the default again" "headphones" "$(val default-after-off)"
check "and the host is stopped: the sink is gone" "0" "$(val sink-after-off)"
finish
