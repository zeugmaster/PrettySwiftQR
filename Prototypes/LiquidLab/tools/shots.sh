# Headless-Chrome helpers for inspecting the lab frame by frame. Source this file, then:
#   strip NAME seqz "MODE,PAYLOAD,RM,RI,RENDER,CX,CY,CW,CELL,P1,P2,..." FRAMES CELL   -> tools/out/s-NAME.png
#   probe "MODE,PAYLOAD,SIZE,P0,P1,STEP,DP"                                         -> blur/pop hotspots per frame
#   endcheck                                                                         -> rest hand-off diff and appear tail
# MODE 4 = pull apart (disappear forward, appear backward), 3 = flow into the checkmark.
LAB="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
OUT="$LAB/tools/out"; mkdir -p "$OUT"
CH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
page() { { echo '<!doctype html><html><head><meta charset="utf-8"></head><body>'; cat "$LAB/liquid-qr-lab.html"; cat "$LAB/tools/$1.js"; echo '</body></html>'; } > "$OUT/$1.html"; }
strip() { page "$2"; "$CH" --headless=new --use-angle=metal --hide-scrollbars --window-size=$(( $4 * ($5 + 6) )),$5 --virtual-time-budget=8000 --screenshot="$OUT/s-$1.png" "file://$OUT/$2.html#rest~$3" >/dev/null 2>&1; }
probe() { page probe; "$CH" --headless=new --use-angle=metal --virtual-time-budget=60000 --dump-dom "file://$OUT/probe.html#rest~$1" 2>/dev/null | sed -n '/<pre id="out">/,/<\/pre>/p' | sed 's/<[^>]*>//g'; }
endcheck() { page endcheck; "$CH" --headless=new --use-angle=metal --virtual-time-budget=30000 --dump-dom "file://$OUT/endcheck.html#rest" 2>/dev/null | sed -n '/<pre id="act">/,/<\/pre>/p' | sed 's/<[^>]*>//g'; }
