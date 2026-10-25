# armbian-a733-gpu

Open-source GPU stack for **Allwinner A733** boards (Imagination PowerVR
**BXM-4-64 MC1**, BVNC `36.56.104.183`) on **Armbian** with the Orange Pi vendor
6.6 kernel: no `pvrsrvkm`, no closed userspace blobs.

This repository is integration work. The GPU driver itself is
[apercel](https://github.com/TumRedSun/apercel) by TumRedSun: an out-of-tree
build of the upstream Linux `imagination` DRM driver plus a Mesa patch. The
driver-side work done here lives in the fork [CheezeCS/apercel](https://github.com/CheezeCS/apercel), which
this repository builds from:

- **30 upstream `drm/imagination` bug fixes backported to apercel** (GPU reset
  deadlock, paired job submission, timeouts, an OOM in page-table
  preallocation, ...; branch `upstream-fixes`);
- a **port of the apercel Mesa patch to Mesa 26.3**, which brings
  `VK_EXT_transform_feedback` for PowerVR and with it **OpenGL ES 3.1 /
  OpenGL 3.2** through zink (Mesa 26.1 stops at ES 2.0 / GL 2.1; branch
  `mesa-26.3`), plus build and firmware fixes in its README.

What this repository adds:

- an **Armbian extension** that builds `apercel.ko` with the image kernel, swaps
  out `pvrsrvkm` and installs the **open firmware** (pinned and checksummed);
- an on-board **Mesa build script** for the apercel patches (Debian trixie);
- a **kernel fix for HDMI "no signal"** after boot or cable re-plug, a bug in
  the vendor `sunxi-drm` display driver (plus a user-space workaround for the
  stock kernel);
- **fan control** for the Orange Pi Zero 3W (its 2-pin fan only runs on/off);
- findings and tools: why Electron/Chromium apps lose GPU acceleration and how
  to get it back, a Vulkan compute smoke test, a headless Wayland test runner.

> **Status: experimental.** Tested on one board. Keep a spare SD card image and a
> second way into the board (serial console or SSH).

## What works

Tested on an **Orange Pi Zero 3W** (4 GB), Armbian trixie, kernel
`6.6.98-vendor-sun60iw2` built by `build.sh`, apercel from
[CheezeCS/apercel](https://github.com/CheezeCS/apercel) (upstream `e098b9f` + backported fixes), firmware
`1.1.OS@6976702`, Mesa 26.3.0-rc2 built with `a733-build-mesa`.

| Item | Result |
|---|---|
| `apercel` probe, open firmware load | works (`FW version v1.1 (build 6976702 OS)`) |
| GPU clock | 1008 MHz (apercel governor) |
| Vulkan 1.3 device (`vulkaninfo`) | works, Mesa 26.1.8 and 26.3.0-rc2 |
| Vulkan compute (`tools/vktest`) | works |
| Vulkan WSI on Wayland (`vkcube --wsi wayland`, headless Weston) | works |
| OpenGL / GLES through zink, Mesa 26.1.8 | GL 2.1, GLES 2.0 |
| OpenGL / GLES through zink, **Mesa 26.3.0-rc2** | **GL 3.2 core, GLES 3.1** |
| `VK_EXT_transform_feedback` | Mesa 26.3 only |
| Electron 45 / Vesktop 1.6.8, Mesa 26.1.8 | GPU disabled (software) unless `--use-angle=vulkan` ([details](docs/electron.md)) |
| Electron 45, **Mesa 26.3** | GPU compositing + WebGL2, no flags needed |
| HDMI console 3440x1440@60, after boot and after cable re-plug | works with kernel patch 0012 ([details](docs/hdmi.md)) |
| apercel with the backported upstream fixes | works: Vulkan, compute, sway + vkcube + Vesktop, no kernel warnings |
| sway 1.10 session on HDMI (3440x1440), Mesa 26.3 | works: GPU compositing (zink), foot, vkcube, Vesktop |
| Vesktop 1.6.8 under sway, Mesa 26.3 | starts and renders (GPU process stays up) |
| Wi-Fi WPA3-SAE (AIC8800), Wi-Fi 6 80 MHz | works; netplan needs a workaround ([details](docs/troubleshooting.md#wi-fi-aic8800-wpa3)) |
| Fan (2-pin header) | works as on/off with hysteresis (60 C on / 50 C off); PWM speed control is impossible with this fan wiring ([details](docs/fan.md)) |
| KDE Plasma 6.3 (Wayland), Mesa 26.3 | tried on the board (not in images): smooth at 1920x1080 (disable Shake Cursor); slow at 3440x1440 ([details](docs/troubleshooting.md#kde-plasma-wayland)) |
| Xfce / X11 session | not tested; expected without GPU acceleration (no glamor path for the split display/render devices) |
| Suspend/resume, long-running stability | not tested |
| `build.sh --kernel-only` (kernel + apercel packages) | built and installed on the test board |
| `build.sh` full image | not yet run end to end |

Other A733 boards (Orange Pi 4 Pro, Radxa Cubie A7A/A7Z) use the same SoC and
GPU. apercel itself was developed on an Orange Pi 4 Pro. Reports welcome.

## Getting it

### Option A: build an image

On an x86-64 or arm64 Linux host (WSL2 works) that the
[Armbian build framework](https://docs.armbian.com/Developer-Guide_Build-Preparation/)
supports:

```bash
git clone https://github.com/CheezeCS/armbian-a733-gpu.git
cd armbian-a733-gpu
./build.sh                       # Orange Pi Zero 3W, trixie
./build.sh --board orangepi4pro  # other sun60iw2 boards
./build.sh --kernel-only         # only the kernel packages (linux-image with apercel.ko)
```

`build.sh` checks out `armbian/build` and apercel (the fork) at tested
commits, copies apercel, the extension and the kernel patches into
`userpatches/` and runs `compile.sh` with
`ENABLE_EXTENSIONS=apercel-a733`. Pass extra Armbian options after `--`, for
example `./build.sh -- PREFER_DOCKER=no` (needed in WSL2 with Docker Desktop
installed but not usable by the build user).

The image contains no Mesa build: the Mesa version that matters (with the
apercel changes) is built on the board, see below.

### Option B: an existing Armbian install

Follow the README of [CheezeCS/apercel](https://github.com/CheezeCS/apercel) for the kernel module (it
needs the matching kernel headers and the three DRM helper modules, see
[docs/troubleshooting.md](docs/troubleshooting.md)). Then install
the pieces from `files/` by hand: firmware (below), `files/sbin/`,
`files/systemd/`, and on the stock kernel `files/hdmi-fix/`.

### Firmware

The module loads `/lib/firmware/apercel/rogue_36.56.104.183_v1.fw`. Use the
open-source build from Imagination's firmware repository (branch `powervr`):

```bash
sudo install -d /lib/firmware/apercel
sudo curl -fL -o /lib/firmware/apercel/rogue_36.56.104.183_v1.fw \
  https://gitlab.freedesktop.org/imagination/linux-firmware/-/raw/8a58f81883f7be458daa34e418cc4079f995b279/powervr/rogue_36.56.104.183_v1.fw
echo "1db1c399c17401d1f79d46c880db81c724d748c784d4639433b076aba2f9c0d2  /lib/firmware/apercel/rogue_36.56.104.183_v1.fw" | sha256sum -c
```

The `rgx.fw.36.56.104.183` file from the vendor packages does **not** work: it
is a `pvrsrvkm` build and the open driver rejects it with
`Unsupported fw info version 2`.

### Mesa (on the board)

```bash
sudo a733-build-mesa                 # Mesa 26.3.0-rc2 + apercel -> /usr/local (30-45 min)
sudo a733-build-mesa --mesa 26.1.8   # apercel's original patch
sudo a733-build-mesa --prefix /opt/mesa-test   # side by side; try it with tools/mesa-run
a733-gpu-check
```

In images built here the script is at `/usr/local/sbin/a733-build-mesa`;
otherwise run `files/mesa/a733-build-mesa` from a checkout; it takes the
patches from the apercel checkout (`/usr/src/apercel`, or `--apercel DIR`).
See [docs/mesa-26.3.md](docs/mesa-26.3.md) for what the 26.3 port changes.

### Wi-Fi on first boot

`tools/image-preset-wifi` writes Armbian
[autoconfig](https://docs.armbian.com/user-guide/autoconfig/) presets into an
image before it is flashed, so a headless board joins Wi-Fi on first boot:

```bash
sudo WIFI_SSID=MyNet WIFI_PSK=secret WIFI_COUNTRY=DE tools/image-preset-wifi Armbian_*.img
```

## Repository layout

```text
build.sh                         image build wrapper around armbian/build
armbian/userpatches/extensions/  apercel-a733.sh, the Armbian extension
armbian/userpatches/kernel/      0011: DRM helper tristates get a prompt
                                 0012: sunxi HDMI output restored after HPD re-plug
files/                           everything installed on the board
  mesa/                          a733-build-mesa (on-board Mesa build)
  hdmi-fix/                      HDMI workaround for the stock kernel (udev + systemd)
  overlay/, fan/                 Zero 3W fan: DT overlay + on/off control service
  sbin/, systemd/                CPU governor + GPU IRQ affinity at boot
  tools/a733-gpu-check           status report
tools/                           test helpers (not installed)
docs/                            findings and background
```

## Documentation

- [docs/hdmi.md](docs/hdmi.md): HDMI "no signal" after boot / re-plug, root cause, fix
- [docs/fan.md](docs/fan.md): Zero 3W fan, why PWM speed control fails, on/off control
- [docs/electron.md](docs/electron.md): Electron/Chromium GPU acceleration, ES 3.0, ANGLE
- [docs/mesa-26.3.md](docs/mesa-26.3.md): the apercel Mesa patch on 26.3
- [docs/linux-7.3.md](docs/linux-7.3.md): the "BXM-4-64 supported in Linux 7.3" news, and the upstream fixes backported to apercel
- [docs/troubleshooting.md](docs/troubleshooting.md): build and bring-up problems and their fixes

## Credits and licences

- [apercel](https://github.com/TumRedSun/apercel) (GPL-2.0 kernel driver, MIT
  Mesa patch) by TumRedSun; the fork [CheezeCS/apercel](https://github.com/CheezeCS/apercel) adds the
  backported upstream fixes (original authors kept) and the Mesa 26.3 port.
- Mesa transform feedback for PowerVR:
  [mesa!44385](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/44385).
- Firmware: Imagination Technologies,
  [imagination/linux-firmware](https://gitlab.freedesktop.org/imagination/linux-firmware),
  downloaded at build time, not redistributed here.
- [Armbian](https://github.com/armbian/build) and the Orange Pi vendor kernel.

Scripts and documentation in this repository: MIT, see [LICENSE](LICENSE).
Kernel patches under `armbian/` and the fan overlay: GPL-2.0, like the code
they patch.
