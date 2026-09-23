#!/bin/bash
# Replace the OpenWrt-packaged /usr/bin/sing-box with the upstream SagerNet build.
# The sing-box package stays selected in custom-config.sh for its init script and UCI config;
# only the binary is swapped, via the image files overlay (must run after prebuild-misc.sh's rsync).
# To bump: change the tag and the sha256 of the .ipk together.
set -euo pipefail

SB_TAG=v1.14.1
SB_SHA256=421ff203e802b262f973f001574ef84ed7250d91a5a2d88e0c0fa9cd3fe8485c

URL="https://github.com/SagerNet/sing-box/releases/download/${SB_TAG}/sing-box_${SB_TAG#v}_openwrt_x86_64.ipk"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Downloading upstream sing-box: $URL"
curl -fsSL -o "$WORK/sing-box.ipk" "$URL"
echo "$SB_SHA256  $WORK/sing-box.ipk" | sha256sum -c -

# An .ipk is a gzip'd outer tar holding control.tar.gz + data.tar.gz + debian-binary.
# Extract only the binary from data.tar.gz; do not install the package.
tar -xzf "$WORK/sing-box.ipk" -C "$WORK" data.tar.gz
tar -xzf "$WORK/data.tar.gz" -C "$WORK" ./usr/bin/sing-box
mkdir -p "$BUILD_ROOT/files/usr/bin"
install -m 0755 "$WORK/usr/bin/sing-box" "$BUILD_ROOT/files/usr/bin/sing-box"
echo "Custom sing-box staged into image overlay:"
"$BUILD_ROOT/files/usr/bin/sing-box" version
