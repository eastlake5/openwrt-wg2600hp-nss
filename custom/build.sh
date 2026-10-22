#!/bin/sh
# Build the image from this branch.
# Usage: custom/build.sh wg2600hp [make options, e.g. -j8]
#
# 1. feeds.conf pinned to fixed feed commits
# 2. feeds update, then lang/golang and net/tailscale from packages master
#    (custom/patches/packages), then feeds install
# 3. files overlay (custom/files/<device>) and config (custom/configs/<device>.config)
# 4. make download && make
set -e
DEV=${1:?usage: custom/build.sh wg2600hp [make options]}
shift
TOP=$(cd "$(dirname "$0")/.." && pwd)
C=$TOP/custom
[ -f "$C/configs/$DEV.config" ] || { echo "unknown device: $DEV" >&2; exit 1; }
cd "$TOP"

# The prerequisite checks parse English tool output.
export LC_ALL=C LANG=C

cp "$C/feeds.conf" feeds.conf
./scripts/feeds update -a

# The packages feed is pinned to an openwrt-24.10 commit; replace lang/golang
# and net/tailscale with the newer ones (applied once).
for p in "$C"/patches/packages/*.patch; do
	if git -C feeds/packages apply --binary --reverse --check "$p" 2>/dev/null; then
		echo "already applied: $(basename "$p")"
	else
		git -C feeds/packages apply --binary "$p"
	fi
done
./scripts/feeds update -i packages
./scripts/feeds install -a

rm -rf files
[ ! -d "$C/files/$DEV" ] || cp -a "$C/files/$DEV" files

cp "$C/configs/$DEV.config" .config
make defconfig
cmp -s .config "$C/configs/$DEV.config" || echo "WARNING: make defconfig changed .config" >&2

make download "$@"
make "$@"
ls -l bin/targets/ipq806x/generic/*"$DEV"*
