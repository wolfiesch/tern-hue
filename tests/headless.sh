#!/bin/bash
# Headless Tern render of the Hue Lights pane against the demo bridge in tests/mock_bridge.py.
#
#   tests/headless.sh [OUT]
#
# Starts the mock bridge and a headless Tern with this plugin loaded, opens the pane through the
# palette command, waits for the rooms to load, selects Living room to open its card, and saves the
# pane alone, cropped from the window and 1600 pixels wide, as `OUT/pane.png` (default OUT is a
# temp dir; the full window shot stays in OUT/serve). No real bridge or light is contacted.
#
# Cropping keeps the shell pane the window opens with, and its prompt, out of the picture; check
# the result before publishing it. Cropping uses macOS `sips`.
set -euo pipefail

OUT=${1:-$(mktemp -d "${TMPDIR:-/tmp}/tern-hue-shots.XXXXXX")}
TERN=${TERN:-/Applications/Tern.app/Contents/MacOS/tern}
HERE=$(cd "$(dirname "$0")/.." && pwd)

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/tern-hue-root.XXXXXX")
CFG=$(mktemp -d "${TMPDIR:-/tmp}/tern-hue-cfg.XXXXXX")
mkdir -p "$OUT" "$ROOT/crates/app" "$ROOT/crates/plugins/fixtures"
ln -s "$HERE" "$ROOT/crates/plugins/fixtures/hue"
CTL="$CFG/ctl.sock"

python3 "$HERE/tests/mock_bridge.py" "$CFG/port" &
BRIDGE=$!
trap 'kill $BRIDGE ${SERVE:-} 2>/dev/null || true; wait 2>/dev/null || true; rm -rf "$ROOT" "$CFG"' EXIT
for _ in $(seq 1 50); do [ -s "$CFG/port" ] && break; sleep 0.1; done
printf 'bridge: 127.0.0.1:%s\nkey: demo\n' "$(cat "$CFG/port")" >"$CFG/hue.yaml"

TERN_HUE_CONFIG="$CFG/hue.yaml" STENCIL_FIXTURE_ROOT="$ROOT/crates/app" TERN_CONFIG_DIR="$CFG" \
	TERN_DAEMON_SOCKET="$CFG/nodaemon.sock" \
	"$TERN" serve --control "$CTL" --out "$OUT" >"$OUT/serve.log" 2>&1 &
SERVE=$!
for _ in $(seq 1 50); do [ -S "$CTL" ] && break; sleep 0.2; done

c() { "$TERN" ctl --control "$CTL" "$@"; }
# Prints the centre of the first node matching selector $1 whose text starts with $2.
centre() {
	c tree "$1" | python3 -c '
import json, sys
for n in json.load(sys.stdin)["nodes"]:
    if n.get("text", "").startswith(sys.argv[1]):
        x, y, w, h = n["rect"]; print(round(x + w / 2), round(y + h / 2)); break' "$2"
}

c size "${WIDTH:-2000}" "${HEIGHT:-640}" >/dev/null
c plugins fixtures >/dev/null
sleep 1
c plugins run plugin.hue.open >/dev/null
ROWS="[data-surface='plugin.hue.panel'] .sf-tbl-row"
for _ in $(seq 1 50); do
	c tree "$ROWS" | grep -q 'Living room' && break
	sleep 0.2
done
read -r x y < <(centre "$ROWS" "Living room")
c click "$x" "$y" >/dev/null
for _ in $(seq 1 25); do
	c tree "[data-role='hue.detail']" | grep -q 'Relax' && break
	sleep 0.2
done
sleep 0.5
c shot window >/dev/null
for _ in $(seq 1 25); do [ -s "$OUT/serve/window.layout.json" ] && break; sleep 0.2; done
# The Hue pane's rectangle in image pixels: layout rects are CSS pixels, the image is scaled.
read -r px py pw ph < <(python3 - "$OUT/serve/window.layout.json" "$OUT/serve/window.png" "${WIDTH:-2000}" <<-'PY'
	import json, struct, sys
	layout, png, width = sys.argv[1], sys.argv[2], int(sys.argv[3])
	with open(png, "rb") as f:
	    scale = struct.unpack(">I", f.read(24)[16:20])[0] / width
	for e in json.load(open(layout))["elements"]:
	    if e["visible"] and e["path"].endswith("section.tn-pane.on.multi") and e["rect"][0] > 0:
	        print(*(round(v * scale) for v in e["rect"]))
	        break
	PY
)
sips -c "$ph" "$pw" --cropOffset "$py" "$px" "$OUT/serve/window.png" --out "$OUT/pane.png" >/dev/null
sips -Z 1600 "$OUT/pane.png" >/dev/null
echo "ok: $OUT/pane.png"
