#!/bin/zsh
# Golden tests for Halo's image actions, driven through the `--run` CLI. Usage: ./Tests/run.sh
# Rebuilds Halo.app when a source file is newer than it, writes fixtures to a temp dir, and
# exits non-zero if any check fails.
set -u
cd "$(dirname "$0")/.."

BIN=Halo.app/Contents/MacOS/Halo
if [[ ! -x $BIN || -n "$(find Sources build.sh -newer $BIN 2>/dev/null)" ]]; then
  echo "Building…"
  ./build.sh >/dev/null || { echo "Build failed"; exit 1; }
fi
HALO=$PWD/$BIN

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
echo "Making fixtures…"
swiftc -O Tests/check.swift -o "$T/check" 2>/dev/null || { echo "check.swift didn't compile"; exit 1; }
swiftc -O Tests/make-fixtures.swift -o "$T/make-fixtures" 2>/dev/null || { echo "make-fixtures.swift didn't compile"; exit 1; }
"$T/make-fixtures" "$T/f" || exit 1
cd "$T/f"

pass=0 fail=0
expect() { # name expected actual
  if [[ "$3" == $~2 ]]; then (( pass++ )); print "PASS  $1"
  else (( fail++ )); print "FAIL  $1: expected '$2', got '$3'"; fi
}
check() { "$T/check" "$@" 2>&1 }
# run <args…>: sets $out (stdout: one output path per line), $err (stderr) and $code.
run() { out=$("$HALO" --run "$@" 2>"$T/err"); code=$?; err=$(<"$T/err") }

# Orientation is baked in for every output format.
for fmt in webp avif gif bmp png; do
  run $fmt rotated.jpg
  expect "convert $fmt keeps rotation (size)" 200x400 "$(check size "$out")"
  expect "convert $fmt keeps rotation (pixels)" yes "$(check upright "$out")"
done

# Fit and scale never write an unchanged copy.
run fit small.jpg
expect "fit on a small image fails" 1 $code
expect "fit says why" "*Already 1920px or smaller*" "$err"
expect "fit writes nothing" "" "$(ls | grep 1920px)"
run scale150 small.jpg
expect "scale above 100% is rejected" 2 $code

# Compress.
run compress transparent.png
expect "compress keeps transparency (format)" "*.webp" "$out"
expect "compress keeps transparency (pixels)" yes "$(check transparent "$out")"
run compress lowq.jpg
expect "compress skips files it can't shrink" 1 $code
expect "compress says why" "*Already well compressed*" "$err"
expect "compress leaves nothing behind" "" "$(ls | grep 'lowq compressed')"
run compress small.jpg
expect "compress shrinks a high-quality JPEG" 0 $code

# WebP.
run webp opaque.png
expect "WebP from PNG is lossless" yes "$(check same opaque.png "$out")"
run webp p3.png
expect "WebP keeps Display P3" kCGColorSpaceDisplayP3 "$(check space "$out")"

# Resizing keeps the pixel format.
run scale50 noalpha.png
expect "resize doesn't add alpha" no "$(check alpha "$out")"
run scale50 deep16.png
expect "resize keeps 16-bit" 16 "$(check depth "$out")"
run strip deep16.png
expect "strip keeps 16-bit" 16 "$(check depth "$out")"

# PDF: pages are A4 or Letter (landscape for a landscape image), and a bad file doesn't sink the rest.
run pdf big72.jpg
expect "PDF page is A4 or Letter landscape" "1 (842x595|792x612)" "$(check pdf "$out")"
for orientation in 1 2 3 4 5 6 7 8; do
  run pdf quad-$orientation.jpg
  expect "PDF page is upright for EXIF orientation $orientation" yes "$(check pdfmatch "$out" quad-$orientation.jpg)"
done
# Control: the check must notice a page that's rotated wrong (the orientation-8 page vs the unrotated image).
expect "pdfmatch catches a wrong rotation" no "$(check pdfmatch "$out" quad-1.jpg)"
run pdf small.jpg
pdf_bytes=$(check bytes "$out") jpg_bytes=$(check bytes small.jpg)
expect "PDF embeds the JPEG as-is (under 1.1× its size)" yes \
  "$( (( pdf_bytes < jpg_bytes * 11 / 10 )) && echo yes || echo no )"
run pdf big72.jpg broken.png
expect "PDF with a bad file reports it" 1 $code
expect "PDF with a bad file names it" "*broken.png*" "$err"
expect "PDF with a bad file still has the good page" "1 *" "$(check pdf "$out")"

# A crash mid-write leaves no empty file in the source folder.
"$HALO" --run png huge.tiff >/dev/null 2>&1 &
sleep 1
kill -9 $! 2>/dev/null
wait $! 2>/dev/null
expect "killed mid-write leaves no 0-byte file" "" "$(find . -name 'huge*.png' -size 0)"

print "\n$pass passed, $fail failed"
(( fail == 0 ))
