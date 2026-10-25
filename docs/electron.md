# Electron / Chromium and GPU acceleration

## Symptom

Electron apps (Vesktop, VS Code, ...) and recent Chromium start, but render in
software. With `--enable-logging=stderr`:

```text
eglCreateContext ES 3.0 failed with error EGL_BAD_ATTRIBUTE. ES version fallback is disabled.
gl::init::CreateGLContext failed
Exiting GPU process due to errors during initialization
...
GPU access is disabled due to frequent crashes.
```

## Cause

Chromium's GPU process (Chromium 152 in Electron 45) requires an **OpenGL ES 3.0**
context and no longer falls back to ES 2.0.

With Mesa 26.1.x, zink on the PowerVR Vulkan driver only reaches **GLES 2.0 /
GL 2.1**. Of the requirements Mesa checks for ES 3.0 (`compute_version_es2()` in
`src/mesa/main/version.c`), exactly one is missing: **`EXT_transform_feedback`**.
zink implements it with `VK_EXT_transform_feedback`, which the PowerVR Vulkan
driver did not implement before Mesa 26.3
([mesa!44385](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/44385),
enabled for both BXM-4-64 variants, `36.52.104.182` and `36.56.104.183`).

## Results (Electron 45, headless Weston, Orange Pi Zero 3W)

| Configuration | GPU compositing | WebGL | WebGL2 |
|---|---|---|---|
| Mesa 26.1.8, default | no (software) | no | no |
| Mesa 26.1.8, `MESA_GLES_VERSION_OVERRIDE=3.0` | yes (zink) | yes | no: "maximum transform feedback separate attribs is too small (0, should be 4)" |
| Mesa 26.1.8, `--use-angle=vulkan` | yes | yes | yes (ANGLE on PowerVR Vulkan) |
| **Mesa 26.3.0-rc2**, default | **yes** (zink, GLES 3.1) | **yes** | **yes** |
| Mesa 26.3.0-rc2, `--use-angle=vulkan` | yes | yes | yes |

Neither Electron 45 nor Vesktop 1.6.8 crashed in these tests. The apercel README
reports that Vesktop does not start on an Orange Pi 4 Pro under sway. On the
Zero 3W with Mesa 26.3, Vesktop 1.6.8 (`--ozone-platform=wayland`) starts under
a real sway 1.10 session on HDMI, shows its setup window, and its GPU process
runs on zink (`libgallium-26.3.0-rc2`, `libvulkan_powervr_mesa`) without
restarts.

## What to do

- **Mesa 26.3** (`sudo a733-build-mesa`): nothing else needed.
- **Mesa 26.1.x**: start Electron apps with `--use-angle=vulkan`. ANGLE then
  renders straight on the PowerVR Vulkan driver, bypassing zink, and emulates
  transform feedback itself. For example, override the desktop entry:

  ```bash
  mkdir -p ~/.local/share/applications
  sed 's|^Exec=\([^ ]*\)|Exec=\1 --use-angle=vulkan|' /usr/share/applications/vesktop.desktop \
    > ~/.local/share/applications/vesktop.desktop
  ```

Still open, both configurations: Chromium logs
`DRM_IOCTL_MODE_CREATE_DUMB failed: Permission denied` /
`Cannot create bo with format=RGBA_8888 and usage=Scanout|Rendering|Texturing`
(it cannot allocate scanout buffers on the display node) and falls back to
another path. Not fatal; possible performance cost.

## Reproducing

`tools/electron-gpuprobe` is a tiny Electron app that prints
`app.getGPUFeatureStatus()` and the WebGL renderer string, then exits.
`tools/headless-weston-run` runs it without a monitor:

```bash
tools/headless-weston-run -t 40 -l /tmp/probe.log -- \
  ./electron --ozone-platform=wayland --enable-logging=stderr tools/electron-gpuprobe
grep PROBE /tmp/probe.log
```
