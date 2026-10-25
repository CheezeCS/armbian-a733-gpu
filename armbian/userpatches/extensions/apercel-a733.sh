# SPDX-License-Identifier: MIT
#
# Armbian extension: open-source PowerVR GPU stack for Allwinner A733
# (sun60iw2, Imagination BXM-4-64 MC1, BVNC 36.56.104.183).
#
# Replaces the vendor pvrsrvkm driver and its closed userspace with:
#   - apercel, the out-of-tree build of the upstream Linux "imagination" DRM driver
#     (https://github.com/TumRedSun/apercel; build.sh uses the fork
#     https://github.com/CheezeCS/apercel with backported upstream fixes),
#     built against the image kernel;
#   - the open-source RGX firmware from Imagination's linux-firmware repository;
#   - Mesa (PowerVR Vulkan + zink) with the apercel changes: the a733-mesa
#     package cross-compiled by build.sh, and the on-board build script;
#   - optionally sway (A733_DESKTOP=sway) and sway autologin (A733_AUTOLOGIN=yes).
# The kernel patches next to this extension make the helpers buildable (0011)
# and fix HDMI after hot-plug in the vendor sunxi-drm driver (0012).
#
# Enable with:  ./compile.sh ... ENABLE_EXTENSIONS=apercel-a733
# Expects (populated by build.sh in this repository):
#   ${USERPATCHES_PATH}/apercel/              apercel checkout
#   ${USERPATCHES_PATH}/a733-opengpu/         files/ from this repository

declare -g APERCEL_DIR="${APERCEL_DIR:-${USERPATCHES_PATH}/apercel}"
declare -g A733_OPENGPU_FILES="${A733_OPENGPU_FILES:-${USERPATCHES_PATH}/a733-opengpu}"

# Open-source firmware for BVNC 36.56.104.183, pinned to a known-good commit of
# https://gitlab.freedesktop.org/imagination/linux-firmware (branch "powervr").
# The blob shipped in the vendor packages (rgx.fw.36.56.104.183) is a pvrsrvkm
# build (fw_info v2) and is rejected by the open driver, so there is no fallback.
declare -g A733_FW_COMMIT="${A733_FW_COMMIT:-8a58f81883f7be458daa34e418cc4079f995b279}"
declare -g A733_FW_SHA256="${A733_FW_SHA256:-1db1c399c17401d1f79d46c880db81c724d748c784d4639433b076aba2f9c0d2}"

function post_family_config__apercel_a733_no_vendor_gpu_userspace() {
	# The vendor GL/Vulkan blobs would shadow Mesa; skip them (sun60iw2.conf honours this).
	declare -g SUN60IW2_GPU_USERSPACE="no"
}

function add_host_dependencies__apercel_a733() {
	declare -g EXTRA_BUILD_DEPS="${EXTRA_BUILD_DEPS} curl device-tree-compiler"
}

# apercel imports symbols from these DRM helpers; build them as modules so
# modprobe can softdep-load them before apercel.ko. PM_OPP is used by
# pvr_power.c to read the GPU OPP table. Needs kernel patch 0011, which gives
# the helper tristates a prompt (otherwise olddefconfig drops the values).
function custom_kernel_config__apercel_a733_helpers() {
	opts_m+=(DRM_SCHED DRM_EXEC DRM_GEM_SHMEM_HELPER)
	opts_y+=(PM_OPP)
}

# Build apercel.ko against the exact kernel just compiled, ship it in the
# linux-image package (/lib/modules/<ver>/extra) and drop pvrsrvkm.ko from the
# package. The 900 prefix orders this after the family's own (default 500)
# hook that builds pvrsrvkm. Removing pvrsrvkm only from the rootfs is not
# enough: a later `dpkg -i` of the kernel package would bring it back, and it
# auto-loads through its own aliases (blacklisting does not stop that).
function pre_package_kernel_image__900_apercel_a733_module() {
	# Substituted by build.sh; part of the hook hash, so the kernel package is
	# rebuilt when the apercel revision changes.
	: "apercel revision @APERCEL_REVISION@"
	[[ -d "${APERCEL_DIR}/driver" ]] || exit_with_error "apercel-a733: apercel sources not found" "${APERCEL_DIR}"
	local kd="${kernel_work_dir}"
	local extra_dir="${tmp_kernel_install_dirs[INSTALL_MOD_PATH]}/lib/modules/${kernel_version_family}/extra"

	display_alert "Building apercel GPU module" "${kernel_version_family}" "info"

	# DRM_SYMVERS only feeds the Makefile's vendoring check. The kernel's own
	# Module.symvers is read automatically, so KBUILD_EXTRA_SYMBOLS must stay
	# empty, or every module-exported symbol is seen twice by modpost.
	run_host_command_logged make -C "${kd}" -j"$(nproc)" ARCH="${ARCHITECTURE}" CROSS_COMPILE="${KERNEL_COMPILER}" \
		DRM_SYMVERS="${kd}/Module.symvers" KBUILD_EXTRA_SYMBOLS= M="${APERCEL_DIR}/driver" modules ||
		exit_with_error "apercel-a733: module build failed"
	[[ -f "${APERCEL_DIR}/driver/apercel.ko" ]] || exit_with_error "apercel-a733: apercel.ko was not produced"

	run_host_command_logged mkdir -p "${extra_dir}"
	run_host_command_logged install -m 644 "${APERCEL_DIR}/driver/apercel.ko" "${extra_dir}/apercel.ko"
	run_host_command_logged "${KERNEL_COMPILER}strip" --strip-debug "${extra_dir}/apercel.ko"
	run_host_command_logged rm -f "${extra_dir}/pvrsrvkm.ko"
	run_host_command_logged depmod -a -b "${tmp_kernel_install_dirs[INSTALL_MOD_PATH]}" -F "${kd}/System.map" "${kernel_version_family}"
}

function post_family_tweaks__apercel_a733_rootfs() {
	display_alert "apercel-a733: rootfs" "${BOARD}" "info"
	local files="${A733_OPENGPU_FILES}"
	[[ -d "${files}" ]] || exit_with_error "apercel-a733: support files not found" "${files}"

	# --- pvrsrvkm out, apercel in ---
	rm -f "${SDCARD}"/lib/modules/*/extra/pvrsrvkm.ko "${SDCARD}"/usr/lib/modules/*/extra/pvrsrvkm.ko
	local vdir
	for vdir in "${SDCARD}"/usr/lib/modules/*/; do
		[[ -f "${vdir}/modules.dep" ]] && depmod -b "${SDCARD}" "$(basename "${vdir}")" 2> /dev/null
	done
	# /etc/modules is pre-seeded from the family MODULES list, which names pvrsrvkm
	sed -i 's/^pvrsrvkm$/apercel/' "${SDCARD}/etc/modules"
	run_host_command_logged install -m 644 -D "${APERCEL_DIR}/conf/99-apercel.conf" "${SDCARD}/etc/modprobe.d/99-apercel.conf"

	# --- open-source firmware, pinned and verified ---
	local fw_dst="${SDCARD}/lib/firmware/apercel/rogue_36.56.104.183_v1.fw"
	local fw_url="https://gitlab.freedesktop.org/imagination/linux-firmware/-/raw/${A733_FW_COMMIT}/powervr/rogue_36.56.104.183_v1.fw"
	run_host_command_logged install -d "$(dirname "${fw_dst}")"
	run_host_command_logged curl -fsSL --retry 3 -o "${fw_dst}" "${fw_url}" ||
		exit_with_error "apercel-a733: firmware download failed" "${fw_url}"
	echo "${A733_FW_SHA256}  ${fw_dst}" | sha256sum -c --quiet - ||
		exit_with_error "apercel-a733: firmware checksum mismatch" "${fw_dst}"

	# --- CPU governor + GPU IRQ affinity (reduces stutter, see apercel README) ---
	run_host_command_logged install -m 755 -D "${files}/sbin/apercel-boot-tune" "${SDCARD}/usr/local/sbin/apercel-boot-tune"
	run_host_command_logged install -m 644 -D "${files}/systemd/gpu-cpu-perf.service" "${SDCARD}/etc/systemd/system/gpu-cpu-perf.service"
	chroot_sdcard systemctl --no-reload enable gpu-cpu-perf.service

	# HDMI after hot-plug is fixed in the kernel (patch 0012); the user-space
	# workaround in files/hdmi-fix/ is only for systems on the stock kernel.

	# --- fan (Orange Pi Zero 3W): on/off with hysteresis, see files/overlay/a733-fan.dts ---
	if [[ "${BOARD}" == "orangepizero3w" ]]; then
		run_host_command_logged install -d "${SDCARD}/boot/overlay-user"
		run_host_command_logged dtc -@ -q -I dts -O dtb -o "${SDCARD}/boot/overlay-user/a733-fan.dtbo" \
			"${files}/overlay/a733-fan.dts" || exit_with_error "apercel-a733: fan overlay does not compile"
		run_host_command_logged install -m 755 -D "${files}/fan/a733-fan-control" "${SDCARD}/usr/local/sbin/a733-fan-control"
		run_host_command_logged install -m 644 -D "${files}/fan/a733-fan-control.service" \
			"${SDCARD}/etc/systemd/system/a733-fan-control.service"
		sed -i 's/\r$//' "${SDCARD}/usr/local/sbin/a733-fan-control" "${SDCARD}/etc/systemd/system/a733-fan-control.service"
		chroot_sdcard systemctl --no-reload enable a733-fan-control.service
	fi

	# --- sources + on-board Mesa build script ---
	rsync -a --exclude .git "${APERCEL_DIR}/" "${SDCARD}/usr/src/apercel/"
	# a733-build-mesa takes the Mesa patches from /usr/src/apercel/mesa/
	run_host_command_logged install -m 755 -D "${files}/mesa/a733-build-mesa" "${SDCARD}/usr/local/sbin/a733-build-mesa"
	run_host_command_logged install -m 755 -D "${files}/tools/a733-gpu-check" "${SDCARD}/usr/local/bin/a733-gpu-check"
	# a Windows checkout may carry CRLF line endings; on-board scripts must be LF
	find "${SDCARD}/usr/src/apercel" "${SDCARD}/usr/local/sbin" "${SDCARD}/usr/local/bin" -type f \
		-exec grep -IlZ $'\r' {} + 2> /dev/null | xargs -0 -r sed -i 's/\r$//'
	sed -i 's/\r$//' "${SDCARD}/etc/systemd/system/gpu-cpu-perf.service"

	# vulkan-tools / mesa-utils for quick checks (vulkaninfo, eglinfo)
	chroot_sdcard_apt_get_install vulkan-tools mesa-utils

	# --- Mesa cross-compiled by build.sh (a733-build-mesa --cross --deb) ---
	local deb
	for deb in "${files}"/debs/a733-mesa_*.deb; do
		[[ -f "${deb}" ]] || continue
		display_alert "apercel-a733: installing" "$(basename "${deb}")" "info"
		run_host_command_logged install -m 644 "${deb}" "${SDCARD}/tmp/"
		chroot_sdcard_apt_get_install "/tmp/$(basename "${deb}")"
		rm -f "${SDCARD}/tmp/$(basename "${deb}")"
	done
	chroot_sdcard ldconfig

	# --- optional desktop (build.sh --desktop sway [--autologin]) ---
	if [[ "${A733_DESKTOP:-none}" == "sway" ]]; then
		display_alert "apercel-a733: desktop" "sway, autologin ${A733_AUTOLOGIN:-no}" "info"
		chroot_sdcard_apt_get_install sway foot xwayland swaybg wmenu fonts-dejavu-core
		if [[ "${A733_AUTOLOGIN:-no}" == "yes" ]]; then
			chroot_sdcard_apt_get_install greetd
			run_host_command_logged install -m 755 -D "${files}/desktop/a733-autologin-config" \
				"${SDCARD}/usr/local/sbin/a733-autologin-config"
			run_host_command_logged install -m 644 -D "${files}/desktop/greetd-a733.conf" \
				"${SDCARD}/etc/systemd/system/greetd.service.d/a733-autologin.conf"
			sed -i 's/\r$//' "${SDCARD}/usr/local/sbin/a733-autologin-config" \
				"${SDCARD}/etc/systemd/system/greetd.service.d/a733-autologin.conf"
			chroot_sdcard systemctl --no-reload enable greetd.service
		fi
	fi
}

# armbianEnv.txt is only complete at the end of the image build: enable the fan
# overlay there (U-Boot's boot-sun60iw2.cmd loads ${user_overlays} from
# /boot/overlay-user/).
function pre_umount_final_image__apercel_a733_fan_overlay() {
	[[ "${BOARD}" == "orangepizero3w" ]] || return 0
	local env="${MOUNT}/boot/armbianEnv.txt"
	[[ -f "${env}" ]] || exit_with_error "apercel-a733: armbianEnv.txt not found" "${env}"
	if grep -q '^user_overlays=' "${env}"; then
		grep -q '^user_overlays=.*\ba733-fan\b' "${env}" || sed -i 's/^user_overlays=\(.*\)/user_overlays=\1 a733-fan/' "${env}"
	else
		echo "user_overlays=a733-fan" >> "${env}"
	fi
	display_alert "apercel-a733: fan overlay enabled" "$(grep '^user_overlays=' "${env}")" "info"
}
