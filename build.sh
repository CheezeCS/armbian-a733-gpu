#!/bin/bash
# SPDX-License-Identifier: MIT
#
# Build an Armbian image for an Allwinner A733 board with the open-source
# PowerVR GPU stack: apercel kernel driver, open firmware and Mesa with the
# apercel changes (cross-compiled here in a Debian trixie chroot, installed in
# the image as the a733-mesa package).
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
#   --mesa VERSION        Mesa for the image: 26.3.0-rc2 (default), 26.1.8 or none
#   --mesa-only           build only the Mesa package (<workdir>/mesa-debs/)
#   --debian-mirror URL   Debian mirror for the Mesa chroot (default: http://deb.debian.org/debian)
#   --desktop sway        install sway, foot and Xwayland (default: none, CLI image)
#   --autologin           with --desktop sway: start sway at boot for the first user
#
# Run as a normal user with sudo rights on a Linux host (or WSL2) supported by
# the Armbian build framework. Output lands in <workdir>/armbian/output/.
# The Mesa chroot needs mmdebstrap (installed with apt if missing).
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
MESA=26.3.0-rc2
DEBIAN_MIRROR_URL=http://deb.debian.org/debian
DESKTOP=none
AUTOLOGIN=no
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
		--mesa) MESA="$2"; shift 2 ;;
		--mesa-only) TARGET=mesa; shift ;;
		--debian-mirror) DEBIAN_MIRROR_URL="$2"; shift 2 ;;
		--desktop) DESKTOP="$2"; shift 2 ;;
		--autologin) AUTOLOGIN=yes; shift ;;
		--) shift; extra=("$@"); break ;;
		-h | --help) sed -n '3,27p' "$0"; exit 0 ;;
		*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
done

[ "$(id -u)" != 0 ] || { echo "run as a normal user; Armbian asks for sudo itself" >&2; exit 1; }
case "$DESKTOP" in none | sway) ;; *) echo "--desktop: none or sway" >&2; exit 2 ;; esac
[ "$AUTOLOGIN" = no ] || [ "$DESKTOP" = sway ] || { echo "--autologin needs --desktop sway" >&2; exit 2; }
[ "$TARGET" != mesa ] || [ "$MESA" != none ] || { echo "--mesa-only with --mesa none" >&2; exit 2; }

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

# Cross-compile Mesa for arm64 in a Debian trixie chroot (amd64 + arm64
# multiarch, the same library versions as the image) with a733-build-mesa.
# The package is cached under <workdir>/mesa-debs/<hash of version, script
# and patches>/; sets mesa_deb.
build_mesa() {
	local root="$WORKDIR/mesa-chroot" key out
	key="$( { echo "$MESA"; cat "$here/files/mesa/a733-build-mesa" "$apercel"/mesa/*.patch; } |
		tr -d '\r' | sha256sum | cut -c1-16)"
	out="$WORKDIR/mesa-debs/$key"
	if ! compgen -G "$out/a733-mesa_*.deb" > /dev/null; then
		[ "$(dpkg --print-architecture)" = amd64 ] || { echo "the Mesa build needs an amd64 host" >&2; exit 1; }
		if [ ! -f "$root/.a733-mesa-chroot" ]; then
			command -v mmdebstrap > /dev/null || sudo apt-get install -y mmdebstrap debian-archive-keyring
			sudo rm -rf "$root"
			sudo mmdebstrap --variant=buildd --architectures=amd64,arm64 \
				--keyring=/usr/share/keyrings/debian-archive-keyring.gpg \
				--include=ca-certificates trixie "$root" "$DEBIAN_MIRROR_URL"
			sudo touch "$root/.a733-mesa-chroot"
		fi
		echo "deb $DEBIAN_MIRROR_URL trixie main" | sudo tee "$root/etc/apt/sources.list" > /dev/null
		tr -d '\r' < "$here/files/mesa/a733-build-mesa" | sudo tee "$root/usr/local/sbin/a733-build-mesa" > /dev/null
		sudo chmod 755 "$root/usr/local/sbin/a733-build-mesa"
		sudo rm -rf "$root/usr/src/apercel" "$root/out"
		sudo mkdir -p "$root/usr/src/apercel"
		sudo cp -r "$apercel/mesa" "$root/usr/src/apercel/"
		sudo cp -L /etc/resolv.conf "$root/etc/resolv.conf"
		sudo mount -t proc proc "$root/proc"
		sudo mount --bind /dev "$root/dev"
		# shellcheck disable=SC2064 # expand now: $root is local to this function
		trap "sudo umount '$root/proc' '$root/dev'" EXIT
		sudo env -i PATH=/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root LANG=C.UTF-8 \
			chroot "$root" /usr/local/sbin/a733-build-mesa --cross --mesa "$MESA" --deb /out
		sudo umount "$root/proc" "$root/dev"
		trap - EXIT
		mkdir -p "$out"
		cp "$root"/out/a733-mesa_*.deb "$out/"
	fi
	mesa_deb="$(compgen -G "$out/a733-mesa_*.deb" | head -1)"
	echo "Mesa package: $mesa_deb"
}

mkdir -p "$WORKDIR"
armbian="$WORKDIR/armbian"
apercel="$WORKDIR/apercel"
up="$armbian/userpatches"
[ "$TARGET" = mesa ] || checkout "$ARMBIAN_REPO" "$ARMBIAN_REF" "$armbian"
checkout "$APERCEL_REPO" "$APERCEL_REF" "$apercel"

mesa_deb=
if [ "$TARGET" != kernel ] && [ "$MESA" != none ]; then
	build_mesa
fi
[ "$TARGET" != mesa ] || exit 0

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
if [ -n "$mesa_deb" ]; then
	mkdir -p "$up/a733-opengpu/debs"
	cp "$mesa_deb" "$up/a733-opengpu/debs/"
fi
# CRLF-proof everything a Windows checkout may have converted
find "$up/extensions" "$up/kernel" "$up/a733-opengpu" "$up/apercel" -type f \
	\( -name '*.sh' -o -name '*.patch' -o -name '*.service' -o -name '*.rules' -o -name '*.conf' -o -perm -u+x \) \
	-exec sed -i 's/\r$//' {} +

cd "$armbian"
args=(BOARD="$BOARD" BRANCH=vendor RELEASE="$RELEASE" KERNEL_CONFIGURE=no
	BUILD_MINIMAL=no BUILD_DESKTOP=no ENABLE_EXTENSIONS=apercel-a733
	A733_DESKTOP="$DESKTOP" A733_AUTOLOGIN="$AUTOLOGIN" "${extra[@]}")
if [ "$TARGET" = kernel ]; then
	./compile.sh kernel "${args[@]}"
else
	./compile.sh build "${args[@]}"
fi
echo "Done. Output: $armbian/output/"
