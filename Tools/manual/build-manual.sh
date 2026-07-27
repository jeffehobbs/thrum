#!/bin/zsh
# Render Tools/manual/manual.html to instructions.pdf via headless Chrome.
# The icon is inlined as a data URI so the PDF is self-contained.
set -e
cd "$(dirname "$0")"
ROOT="../.."
OUT="$(cd "$ROOT" && pwd)/instructions.pdf"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ICON="$ROOT/Assets.xcassets/AppIcon.appiconset/icon_512.png"
sips -Z 200 "$ICON" --out "$WORK/ico.png" >/dev/null
B64=$(base64 -i "$WORK/ico.png" | tr -d '\n')

# Substitute the icon placeholder with the data URI.
python3 - "$WORK" "$B64" <<'PY'
import sys, pathlib
work, b64 = sys.argv[1], sys.argv[2]
html = pathlib.Path("manual.html").read_text()
html = html.replace("ICON", "data:image/png;base64," + b64)
pathlib.Path(work, "manual.html").write_text(html)
PY

"$CHROME" --headless --disable-gpu --no-sandbox \
  --virtual-time-budget=6000 \
  --no-pdf-header-footer \
  --print-to-pdf="$OUT" \
  "file://$WORK/manual.html" 2>/dev/null

echo "wrote $OUT"
