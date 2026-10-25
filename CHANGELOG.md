# Changelog

## Unreleased

- Armbian extension `apercel-a733`: builds apercel with the image kernel,
  replaces `pvrsrvkm`, installs the open RGX firmware pinned to
  imagination/linux-firmware `8a58f818` with SHA256 verification (the previous
  overlay downloaded from a non-existent `main` branch and silently fell back
  to the unusable vendor firmware).
- Kernel patch 0011: DRM helper tristates get a prompt so they can be built as
  modules for apercel.
- Kernel patch 0012: sunxi HDMI output is re-enabled after an HPD re-plug
  (verified after boot and cable re-plug). The udev + `modetest` workaround in
  `files/hdmi-fix/` is kept for stock kernels and no longer installed by the
  extension.
- apercel is now built from the fork https://github.com/CheezeCS/apercel: 30 upstream
  drm/imagination fixes backported (original authors kept) + 3 adaptations for
  6.6 (NO_HANG emulation, Makefile, `drm_driver.date`), the Mesa 26.3 patch, a
  build fix for the 26.1.8 patch (`DRM_PVR_BO_CPU_CACHED`), `.gitattributes`
  (LF) and README fixes (open firmware, Debian trixie build). The former
  `apercel-patches/` series and the Mesa patch copy left this repository.
- `pvrsrvkm.ko` is removed from the kernel package itself, not only from the
  rootfs (a package upgrade brought it back and it auto-loaded).
- Fan on the Orange Pi Zero 3W: the 2-pin fan only runs on a constant level, so
  the vendor PWM levels never started it. New overlay (`files/overlay/a733-fan.dts`:
  levels 0/255, kernel fan bindings moved to the critical trips) and
  `a733-fan-control` service (on at 60 C, off at 50 C), installed by the
  extension for `orangepizero3w`.
- `build.sh`: refs resolve remotely or locally, no silent fallback, the origin
  URL follows `--apercel-repo`; the apercel commit is stamped into the extension
  hook so Armbian's kernel cache is invalidated when it changes.
- apercel Mesa patch ported to Mesa 26.3.0-rc2: `VK_EXT_transform_feedback`,
  GLES 3.1 / GL 3.2 through zink, Electron GPU acceleration without flags.
- `a733-build-mesa`: on-board Mesa build for Debian trixie (26.3.0-rc2 or
  26.1.8), pinned tarball checksums.
- Tools: `a733-gpu-check`, `vktest`, `electron-gpuprobe`, `headless-weston-run`,
  `mesa-run`, `image-preset-wifi`.
- Documentation: HDMI, Electron, Mesa 26.3 port, Linux 7.3, troubleshooting.
