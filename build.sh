#!/bin/bash
# Build a device image with the official OpenWrt ImageBuilder: the device's extra packages, AmneziaWG from
# awg-openwrt, sing-box and the overlay files. Usage: ./build.sh <device>, where <device> is a directory
# with device.env, versions.env, packages.txt and files/ (x86, mx5500).
# Runs the same on a workstation and in GitHub Actions (.github/workflows/build-*.yml).
# Needs: git, curl, rsync, zstd, the ImageBuilder prerequisites (make, gawk, patch, ...) and, for a device
# that builds sing-box from source, go (>= sing-box's go.mod).
# Output: .build/<device>/out with the images, manifest, sha256sums and BUILDINFO.
set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")" && pwd)
DEVICE=${1:?usage: $0 <device>}
DEVICE_DIR=$REPO_DIR/$DEVICE
[ -f "$DEVICE_DIR/device.env" ] || { echo "no such device: $DEVICE"; exit 1; }
# TARGET, PROFILE, ARCH_PACKAGES; optional EXTRA_IMAGE_NAME, ROOTFS_PARTSIZE, SINGBOX_BUILD_TAGS + SINGBOX_GOARCH
. "$DEVICE_DIR/device.env"
# OPENWRT_VERSION, SINGBOX_TAG + SINGBOX_COMMIT or SINGBOX_IPK_SHA256, AWG_TAG/*_SHA256
. "$DEVICE_DIR/versions.env"
WORK_DIR=${WORK_DIR:-$REPO_DIR/.build/$DEVICE}
OUT_DIR=$WORK_DIR/out
rm -rf "$OUT_DIR"
mkdir -p "$WORK_DIR" "$OUT_DIR"

if [ -n "${SINGBOX_BUILD_TAGS:-}" ]; then
    echo "==> sing-box $SINGBOX_TAG from source (slim: $SINGBOX_BUILD_TAGS) for $SINGBOX_GOARCH"
    SB_SRC=$WORK_DIR/sing-box-src
    rm -rf "$SB_SRC"
    git clone -q --depth 1 -b "$SINGBOX_TAG" https://github.com/SagerNet/sing-box.git "$SB_SRC"
    [ "$(git -C "$SB_SRC" rev-parse HEAD)" = "$SINGBOX_COMMIT" ] || { echo "sing-box $SINGBOX_TAG is not commit $SINGBOX_COMMIT"; exit 1; }
    SB_VERSION="${SINGBOX_TAG#v}-slim"
    (cd "$SB_SRC" && GOOS=linux GOARCH=$SINGBOX_GOARCH CGO_ENABLED=0 go build -trimpath \
        -ldflags "-X 'github.com/sagernet/sing-box/constant.Version=$SB_VERSION' $(cat release/LDFLAGS) -s -w -buildid=" \
        -tags "$SINGBOX_BUILD_TAGS" -o "$WORK_DIR/sing-box.bin" ./cmd/sing-box)
    SB_INFO="$SINGBOX_TAG ($SINGBOX_COMMIT), tags $SINGBOX_BUILD_TAGS, $(go version)"
else
    # The upstream release build, binary only: the OpenWrt sing-box package in packages.txt provides the
    # init script and UCI config, and the overlay replaces its /usr/bin/sing-box.
    SB_IPK=sing-box_${SINGBOX_TAG#v}_openwrt_$ARCH_PACKAGES.ipk
    echo "==> sing-box $SINGBOX_TAG upstream build ($SB_IPK)"
    SB_DIR=$WORK_DIR/sing-box-ipk
    rm -rf "$SB_DIR"
    mkdir -p "$SB_DIR"
    curl -fsSL -o "$SB_DIR/$SB_IPK" "https://github.com/SagerNet/sing-box/releases/download/$SINGBOX_TAG/$SB_IPK"
    echo "$SINGBOX_IPK_SHA256  $SB_DIR/$SB_IPK" | sha256sum -c -
    # An .ipk is a gzip'd outer tar holding control.tar.gz + data.tar.gz + debian-binary
    tar -xzf "$SB_DIR/$SB_IPK" -C "$SB_DIR" data.tar.gz
    tar -xzf "$SB_DIR/data.tar.gz" -C "$SB_DIR" ./usr/bin/sing-box
    mv "$SB_DIR/usr/bin/sing-box" "$WORK_DIR/sing-box.bin"
    SB_INFO="$SINGBOX_TAG upstream $SB_IPK ($SINGBOX_IPK_SHA256)"
fi

echo "==> ImageBuilder $OPENWRT_VERSION $TARGET"
IB_BASE=https://downloads.openwrt.org/releases/$OPENWRT_VERSION/targets/$TARGET
IB_NAME=openwrt-imagebuilder-$OPENWRT_VERSION-${TARGET//\//-}.Linux-x86_64
if [ ! -d "$WORK_DIR/$IB_NAME" ]; then
    curl -fsSL -o "$WORK_DIR/ib.tar.zst" "$IB_BASE/$IB_NAME.tar.zst"
    curl -fsSL "$IB_BASE/sha256sums" | grep " \*$IB_NAME.tar.zst\$" | awk '{print $1"  ib.tar.zst"}' > "$WORK_DIR/ib.sha256"
    (cd "$WORK_DIR" && sha256sum -c ib.sha256)
    tar --zstd -xf "$WORK_DIR/ib.tar.zst" -C "$WORK_DIR"
    rm -f "$WORK_DIR/ib.tar.zst"
fi
# Image file names without the version (it is in the release tag), so an asset keeps one URL across
# releases: .../releases/latest/download/openwrt-x86-64-generic-squashfs-combined-efi.img.gz
sed -i 's/^CONFIG_VERSION_FILENAMES=y$/# CONFIG_VERSION_FILENAMES is not set/' "$WORK_DIR/$IB_NAME/.config"

echo "==> AmneziaWG packages (awg-openwrt $AWG_TAG) into the ImageBuilder's local repository"
AWG_SUFFIX=${AWG_TAG}_${ARCH_PACKAGES}_${TARGET//\//_}.apk
mkdir -p "$WORK_DIR/$IB_NAME/packages"
for p in "kmod-amneziawg:$AWG_KMOD_SHA256" "amneziawg-tools:$AWG_TOOLS_SHA256"; do
    f="$WORK_DIR/$IB_NAME/packages/${p%%:*}_$AWG_SUFFIX"
    curl -fsSL -o "$f" "https://github.com/Slava-Shchipunov/awg-openwrt/releases/download/$AWG_TAG/${p%%:*}_$AWG_SUFFIX"
    echo "${p#*:}  $f" | sha256sum -c -
    # apk finds local packages by their canonical <name>-<version>.apk file name, not the release asset name
    v=$("$WORK_DIR/$IB_NAME/staging_dir/host/bin/apk" adbdump "$f" | awk '$1 == "version:" {print $2; exit}')
    mv -f "$f" "$WORK_DIR/$IB_NAME/packages/${p%%:*}-$v.apk"
done
rm -f "$WORK_DIR/$IB_NAME/packages/packages.adb"   # re-indexed by the image build

echo "==> overlay files"
FILES=$WORK_DIR/files
rm -rf "$FILES"
mkdir -p "$FILES/usr/bin"
# Shared by all devices: etcgit, its sysupgrade hook and login banner, clean-overlay, UDP GRO hook
rsync -a "$REPO_DIR/files/" "$FILES/"
rsync -a "$DEVICE_DIR/files/" "$FILES/"
install -m 0755 "$WORK_DIR/sing-box.bin" "$FILES/usr/bin/sing-box"

echo "==> image"
PACKAGES=$(grep -v -E '^\s*(#|$)' "$DEVICE_DIR/packages.txt" | tr '\n' ' ')
# Only the options the device sets: an empty ROOTFS_PARTSIZE= still changes the image build
make -C "$WORK_DIR/$IB_NAME" image PROFILE="$PROFILE" PACKAGES="$PACKAGES" FILES="$FILES" BIN_DIR="$OUT_DIR" \
    ${EXTRA_IMAGE_NAME:+EXTRA_IMAGE_NAME="$EXTRA_IMAGE_NAME"} ${ROOTFS_PARTSIZE:+ROOTFS_PARTSIZE="$ROOTFS_PARTSIZE"}
if ls "$OUT_DIR" | grep -F -- "$OPENWRT_VERSION"; then
    echo "the version is still in these file names"
    exit 1
fi

{
    echo "openwrt: $OPENWRT_VERSION $TARGET $PROFILE${ROOTFS_PARTSIZE:+, rootfs ${ROOTFS_PARTSIZE} MB}"
    echo "packages: $PACKAGES"
    echo "sing-box: $SB_INFO"
    echo "amneziawg: awg-openwrt $AWG_TAG (kmod $AWG_KMOD_SHA256, tools $AWG_TOOLS_SHA256)"
    echo "repo: $(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
} > "$OUT_DIR/BUILDINFO"
cat "$OUT_DIR/BUILDINFO"
ls -l "$OUT_DIR"
