#!/bin/sh
# Builds corpus/: JPEGs from libjpeg-turbo's cjpeg across sizes, subsampling, progressive, restarts, quality, grey/RGB, from
# synthetic images and (if given) photos: scripts/make_corpus.sh [PHOTO.jpg ...]. Needs Pillow (for the sources) and cjpeg.
set -e
CJPEG=${CJPEG:-/opt/homebrew/opt/jpeg-turbo/bin/cjpeg}
PY=${PY:-python3}
cd "$(dirname "$0")/.."
rm -rf corpus; mkdir -p corpus/src
"$PY" - "$@" <<'PYEOF'
import sys, random
from PIL import Image, ImageDraw, ImageFilter
random.seed(7)
def save(im, name): im.convert("RGB").save(f"corpus/src/{name}.ppm")
for w, h in ((1, 1), (3, 2), (7, 9), (16, 16), (17, 31), (63, 65), (255, 129)):
    im = Image.new("RGB", (w, h))
    im.putdata([(random.randrange(256), (x * 255) // max(w - 1, 1), (y * 255) // max(h - 1, 1)) for y in range(h) for x in range(w)])
    save(im, f"syn{w}x{h}")
im = Image.new("RGB", (333, 221), (200, 30, 40)); d = ImageDraw.Draw(im)
for i in range(60):
    x0, y0 = random.randrange(300), random.randrange(200)
    d.ellipse([x0, y0, x0 + random.randrange(1, 120), y0 + random.randrange(1, 80)],
              fill=tuple(random.randrange(256) for _ in range(3)))
save(im.filter(ImageFilter.GaussianBlur(1)), "shapes333x221")
save(Image.effect_noise((257, 193), 90).convert("RGB"), "noise257x193")
for i, p in enumerate(sys.argv[1:]):
    im = Image.open(p).convert("RGB")
    save(im.resize((640, round(640 * im.height / im.width))), f"photo{i}_640")
    if i < 3:
        save(im, f"photo{i}_full")
PYEOF
for src in corpus/src/*.ppm; do
  b=$(basename "$src" .ppm)
  case "$b" in *_full) # the benchmark set: the usual encodings only
    "$CJPEG" -quality 85 "$src" > "corpus/$b-q85-420.jpg"
    "$CJPEG" -quality 92 -sample 1x1 "$src" > "corpus/$b-q92-444.jpg"
    "$CJPEG" -quality 85 -progressive "$src" > "corpus/$b-q85-420-prog.jpg"
    continue;; esac
  for q in 5 50 85 100; do "$CJPEG" -quality $q "$src" > "corpus/$b-q$q-420.jpg"; done
  for s in 1x1 2x1 1x2 4x1 2x2,1x2,2x1 1x1,2x2,1x1; do
    "$CJPEG" -quality 80 -sample $s "$src" > "corpus/$b-s$s.jpg"
    "$CJPEG" -quality 80 -sample $s -progressive "$src" > "corpus/$b-s$s-prog.jpg"
  done
  "$CJPEG" -quality 75 -optimize "$src" > "corpus/$b-opt.jpg"
  "$CJPEG" -quality 75 -restart 1B "$src" > "corpus/$b-rst1b.jpg"
  "$CJPEG" -quality 75 -restart 3B -progressive "$src" > "corpus/$b-rst3b-prog.jpg"
  "$CJPEG" -quality 75 -restart 1 -sample 1x1 "$src" > "corpus/$b-rst1row.jpg"
  "$CJPEG" -quality 75 -grayscale "$src" > "corpus/$b-grey.jpg"
  "$CJPEG" -quality 75 -grayscale -progressive "$src" > "corpus/$b-grey-prog.jpg"
  "$CJPEG" -quality 75 -rgb "$src" > "corpus/$b-rgb.jpg"
  "$CJPEG" -quality 10 -baseline -smooth 30 "$src" > "corpus/$b-smooth.jpg"
done
rm -rf corpus/src
ls corpus | wc -l
