#!/usr/bin/env bash

set -e

INPUT="StuffBucket-1024.png"
OUTDIR="AppIcon"

if [[ ! -f "$INPUT" ]]; then
  echo "Input file $INPUT not found"
  exit 1
fi

mkdir -p "$OUTDIR"

# iOS / iPadOS
sizes_ios=(
  20
  29
  40
  58
  60
  76
  80
  87
  120
  152
  167
  180
)

# macOS
sizes_macos=(
  16
  32
  64
  128
  256
  512
  1024
)

echo "Generating iOS / iPadOS icons..."
for size in "${sizes_ios[@]}"; do
  magick "$INPUT" -resize "${size}x${size}" \
    "$OUTDIR/icon-${size}x${size}.png"
done

echo "Generating macOS icons..."
for size in "${sizes_macos[@]}"; do
  magick "$INPUT" -resize "${size}x${size}" \
    "$OUTDIR/icon-mac-${size}x${size}.png"
done

echo "Done. Icons written to $OUTDIR/"