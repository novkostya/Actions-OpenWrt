#!/bin/bash
# Build the Linksys MX5500 AP image: OpenWrt ImageBuilder + extra packages + a slim sing-box + overlay files.
# Runs the same on a workstation and in GitHub Actions (.github/workflows/build-mx5500.yml).
# Needs: go (>= sing-box's go.mod), git, curl, zstd, and the ImageBuilder prerequisites (make, gawk, patch, ...).
# Output: $OUT_DIR with the sysupgrade/factory images, manifest, sha256sums and BUILDINFO.
set -euo pipefail

TARGET=qualcommax/ipq50xx
PROFILE=linksys_mx5500
# Only what the AP needs: Hysteria2/Realms (QUIC). Tailscale comes from the OpenWrt package instead.
SINGBOX_BUILD_TAGS=with_quic,badlinkname,tfogo_checklinkname0

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
# Versions and checksums: OPENWRT_VERSION, SINGBOX_TAG/COMMIT, AWG_TAG/*_SHA256
. "$REPO_DIR/mx5500/versions.env"
WORK_DIR=${WORK_DIR:-$REPO_DIR/.build-mx5500}
OUT_DIR=${OUT_DIR:-$WORK_DIR/out}
mkdir -p "$WORK_DIR" "$OUT_DIR"

echo "==> sing-box $SINGBOX_TAG (slim: $SINGBOX_BUILD_TAGS) for arm64"
SB_SRC=$WORK_DIR/sing-box-src
rm -rf "$SB_SRC"
git clone -q --depth 1 -b "$SINGBOX_TAG" https://github.com/SagerNet/sing-box.git "$SB_SRC"
[ "$(git -C "$SB_SRC" rev-parse HEAD)" = "$SINGBOX_COMMIT" ] || { echo "sing-box $SINGBOX_TAG is not commit $SINGBOX_COMMIT"; exit 1; }
SB_VERSION="${SINGBOX_TAG#v}-slim"
(cd "$SB_SRC" && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath \
    -ldflags "-X 'github.com/sagernet/sing-box/constant.Version=$SB_VERSION' $(cat release/LDFLAGS) -s -w -buildid=" \
    -tags "$SINGBOX_BUILD_TAGS" -o "$WORK_DIR/sing-box.bin" ./cmd/sing-box)

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

echo "==> AmneziaWG packages (awg-openwrt $AWG_TAG) into the ImageBuilder's local repository"
AWG_SUFFIX=${AWG_TAG}_aarch64_cortex-a53_${TARGET//\//_}.apk
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
# Shared with the x86 VM image: etcgit, its sysupgrade hook and login banner, clean-overlay.
rsync -a "$REPO_DIR/files/" "$FILES/"
rsync -a "$REPO_DIR/mx5500/files/" "$FILES/"
install -m 0755 "$WORK_DIR/sing-box.bin" "$FILES/usr/bin/sing-box"

echo "==> image"
PACKAGES=$(grep -v -E '^\s*(#|$)' "$REPO_DIR/mx5500/packages.txt" | tr '\n' ' ')
make -C "$WORK_DIR/$IB_NAME" image PROFILE="$PROFILE" PACKAGES="$PACKAGES" FILES="$FILES" \
    BIN_DIR="$OUT_DIR" EXTRA_IMAGE_NAME=mx5500-ap

{
    echo "openwrt: $OPENWRT_VERSION $TARGET $PROFILE"
    echo "packages: $PACKAGES"
    echo "sing-box: $SINGBOX_TAG ($SINGBOX_COMMIT), tags $SINGBOX_BUILD_TAGS, $(go version)"
    echo "amneziawg: awg-openwrt $AWG_TAG (kmod $AWG_KMOD_SHA256, tools $AWG_TOOLS_SHA256)"
    echo "repo: $(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
} > "$OUT_DIR/BUILDINFO"
cat "$OUT_DIR/BUILDINFO"
ls -l "$OUT_DIR"
