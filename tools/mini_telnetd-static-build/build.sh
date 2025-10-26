#!/bin/sh
set -eu

# Configuration
TOOLCHAIN_DIR="./arm-linux-musleabihf-cross"
GCC="${TOOLCHAIN_DIR}/bin/arm-linux-musleabihf-gcc"
STRIP="${TOOLCHAIN_DIR}/bin/arm-linux-musleabihf-strip"

# Setup toolchain
if [ ! -f "$GCC" ]; then
    echo "Downloading toolchain..."
    wget -q https://musl.cc/arm-linux-musleabihf-cross.tgz
    tar xzf arm-linux-musleabihf-cross.tgz
    rm -f arm-linux-musleabihf-cross.tgz
fi

# Compile
echo "Compiling..."
"$GCC" \
    -static \
    -march=armv7-a -mfpu=neon \
    -Os -flto -ffunction-sections -fdata-sections \
    -Wl,--gc-sections -Wl,--strip-all \
    -fno-asynchronous-unwind-tables -fno-unwind-tables \
    -o mini_telnetd mini_telnetd.c

# Strip
"$STRIP" mini_telnetd

# Compress (optional)
if command -v upx >/dev/null 2>&1; then
    echo "Compressing..."
    upx --best --lzma mini_telnetd 2>/dev/null || true
fi

echo "Done: mini_telnetd ($(stat -c%s mini_telnetd 2>/dev/null || stat -f%z mini_telnetd) bytes)"
