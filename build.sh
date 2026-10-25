#!/bin/bash
# SPDX-License-Identifier: MIT
#
# Build an Armbian image for an Allwinner A733 board with the open-source
# PowerVR GPU stack (apercel kernel driver + open firmware; Mesa is built on
# the board with a733-build-mesa).
#
#   ./build.sh [options] [-- extra compile.sh arguments]
#
#   --board NAME          Armbian board (default: orangepizero3w)
#   --release NAME        Debian/Ubuntu release (default: trixie)
#   --workdir DIR         where Armbian and apercel are checked out (default: ./work)
#   --armbian-ref REF     armbian/build commit or branch (default: pinned, tested)
#   --apercel-repo URL    apercel repository (default: https://github.com/CheezeCS/apercel)
#   --apercel-ref REF     apercel commit or branch, remote or local (default: pinned, tested)
#   --kernel-only         build only the kernel packages (no image)
#
# Run as a normal user with sudo rights on a Linux host (or WSL2) supported by
# the Armbian build framework. Output lands in <workdir>/armbian/output/.
# The checkouts in <workdir> are owned by this script (local changes are discarded).

set -euo pipefail

here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

BOARD=orangepizero3w
RELEASE=trixie
WORKDIR="$here/work"
# Last combination built and tested on hardware.
ARMBIAN_REPO=https://github.com/armbian/build.git
ARMBIAN_REF=fac57a02f1c6ff2221a3f3099a1094dcdf41be26
# apercel fork with the backported upstream drm/imagination fixes, the Mesa 26.3
# patch and the Zero 3W notes (upstream: https://github.com/TumRedSun/apercel).
APERCEL_REPO=https://github.com/CheezeCS/apercel.git
APERCEL_REF=d03675d4a38e1aa8eb7c0e982e213893a8631baa
TARGET=build
extra=()

while [ $# -gt 0 ]; do
	case "$1" in
		--board) BOARD="$2"; shift 2 ;;
		--release) RELEASE="$2"; shift 2 ;;
		--workdir) WORKDIR="$2"; shift 2 ;;
		--armbian-ref) ARMBIAN_REF="$2"; shift 2 ;;
		--apercel-repo) APERCEL_REPO="$2"; shift 2 ;;
		--apercel-ref) APERCEL_REF="$2"; shift 2 ;;
		--kernel-only) TARGET=kernel; shift ;;
		--) shift; extra=("$@"); break ;;
		-h | --help) sed -n '3,21p' "$0"; exit 0 ;;
		*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
done

[ "$(id -u)" != 0 ] || { echo "run as a normal user; Armbian asks for sudo itself" >&2; exit 1; }

checkout() { # url ref dir
	if [ ! -d "$3/.git" ]; then
		git clone --filter=blob:none "$1" "$3"
	fi
	git -C "$3" remote set-url origin "$1" # the URL may have changed (e.g. upstream -> fork)
	local rev
	if git -C "$3" fetch --quiet origin "$2" 2> /dev/null; then
		rev=FETCH_HEAD # remote branch, tag or commit
	elif git -C "$3" rev-parse -q --verify "$2^{commit}" > /dev/null; then
		rev="$2" # local-only branch or commit
	else
		echo "$(basename "$3"): cannot find '$2' locally or on origin" >&2
		exit 1
	fi
	git -C "$3" checkout --quiet --force --detach "$rev"
	echo "$(basename "$3"): $(git -C "$3" rev-parse --short HEAD)"
}

mkdir -p "$WORKDIR"
armbian="$WORKDIR/armbian"
apercel="$WORKDIR/apercel"
up="$armbian/userpatches"
checkout "$ARMBIAN_REPO" "$ARMBIAN_REF" "$armbian"
checkout "$APERCEL_REPO" "$APERCEL_REF" "$apercel"

# Revision stamp for the Armbian kernel cache: Armbian hashes the extension's
# hook bodies, not the apercel sources, so put the apercel commit into the hook.
apercel_rev="$(git -C "$apercel" rev-parse HEAD)"

# --- populate userpatches (refreshed on every run) ---
mkdir -p "$up/extensions" "$up/kernel/archive"
sed "s/@APERCEL_REVISION@/$apercel_rev/" "$here/armbian/userpatches/extensions/apercel-a733.sh" \
	> "$up/extensions/apercel-a733.sh"
cp -r "$here/armbian/userpatches/kernel/archive/." "$up/kernel/archive/"
rm -rf "$up/apercel" "$up/a733-opengpu"
rsync -a --exclude .git "$apercel/" "$up/apercel/"
cp -r "$here/files" "$up/a733-opengpu"
# CRLF-proof everything a Windows checkout may have converted
find "$up/extensions" "$up/kernel" "$up/a733-opengpu" "$up/apercel" -type f \
	\( -name '*.sh' -o -name '*.patch' -o -name '*.service' -o -name '*.rules' -o -name '*.conf' -o -perm -u+x \) \
	-exec sed -i 's/\r$//' {} +

cd "$armbian"
args=(BOARD="$BOARD" BRANCH=vendor RELEASE="$RELEASE" KERNEL_CONFIGURE=no
	BUILD_MINIMAL=no BUILD_DESKTOP=no ENABLE_EXTENSIONS=apercel-a733 "${extra[@]}")
if [ "$TARGET" = kernel ]; then
	./compile.sh kernel "${args[@]}"
else
	./compile.sh build "${args[@]}"
fi
echo "Done. Output: $armbian/output/"
