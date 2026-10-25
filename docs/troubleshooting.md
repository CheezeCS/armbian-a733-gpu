# Troubleshooting

Problems hit while bringing apercel up on an Orange Pi Zero 3W, in the order
they appear, with the fix used here.

## Kernel module

**`apercel.ko` fails to link: undefined `drm_sched_*`, `drm_exec_*`,
`drm_gem_shmem_*` symbols.**
In the vendor 6.6 tree `DRM_SCHED`, `DRM_EXEC` and `DRM_GEM_SHMEM_HELPER` are
prompt-less ("hidden") tristates, so a value set in `.config` is dropped by
`olddefconfig`. Patch `0011-enable-prompts-for-drm-helper-tristates.patch`
gives them a prompt and `default m`; the extension then sets them to `m`.

**modpost reports every exported symbol twice.**
The kernel's `Module.symvers` is read automatically; passing it again through
`KBUILD_EXTRA_SYMBOLS` duplicates it. Build with `KBUILD_EXTRA_SYMBOLS=`
(empty) on the `make` command line, as the extension does.

**`insmod: ERROR ... Invalid parameters` with `BPF: Invalid name` /
`failed to validate module [apercel] BTF: -22` in dmesg.**
A module's BTF is split BTF on top of the BTF of the exact kernel build it was
compiled against. A module built against a different build of the "same"
kernel (other patches or config, e.g. after adding a kernel patch) is rejected
by the running kernel. Install the module together with its kernel package.
For a quick test on the old kernel, BTF can be dropped (it is optional for
modules): `aarch64-linux-gnu-objcopy --remove-section=.BTF apercel.ko`.

**One `WARNING ... drm_copy_field` / `BUG: the value to copy was not set!` per
boot, and `Initialized apercel 1.0.0 (null)`.**
apercel's `struct drm_driver` has no `.date`; kernels before 6.14 require it.
Harmless; fixed in the fork (`apercel: set drm_driver.date on kernels before
6.14`).

## Firmware

**`Unsupported fw info version 2`, GPU probe fails.**
The vendor `rgx.fw.36.56.104.183` is built for `pvrsrvkm` (fw_info v2, no
open-source flag). Use `rogue_36.56.104.183_v1.fw` from
[imagination/linux-firmware](https://gitlab.freedesktop.org/imagination/linux-firmware),
branch `powervr` (not `main`), see the README.

## Mesa

**`vulkaninfo` finds no device although the module is loaded.**
Mesa looks for the DRM driver by name. Upstream expects `powervr`, apercel
registers `apercel`; the apercel Mesa patch changes `PVR_DRM_DRIVER_NAME`. If
the patch did not apply (for example a CRLF copy from a Windows checkout, or a
build tree reused without the patch), Vulkan silently finds nothing. Check with
`strings libvulkan_powervr_mesa.so | grep -x apercel`. `a733-build-mesa`
always starts from a fresh tree and strips CR from the patch.

**`DRM_PVR_BO_CPU_CACHED` undeclared.**
See [mesa-26.3.md](mesa-26.3.md): define it as `0`.

**`ERROR: Value "builtin" ... for option "mesa-clc"`** or missing `mesa_clc` /
`libclc` / `glslang` on Debian. See the build dependency section of
[mesa-26.3.md](mesa-26.3.md): use `-Dllvm=enabled -Dmesa-clc=enabled` with LLVM 19.

## Scripts

**`pvrsrvkm` is loaded next to apercel after installing a kernel package.**
The vendor family hook builds `pvrsrvkm.ko` into the linux-image package, and it
auto-loads through its device aliases even when blacklisted. The extension
deletes it from the package; on an existing system:
`sudo rm /lib/modules/$(uname -r)/extra/pvrsrvkm.ko && sudo depmod -a`.

**`$'\r': command not found` on the board.**
Files copied from a Windows checkout have CRLF line endings. The build strips
them; for manual copies use `sed -i 's/\r$//' file`.

## KDE Plasma (Wayland)

Plasma 6.3 runs with GPU compositing (KWin picks `card0` for output and renders
OpenGL 3.2 through zink on the PowerVR), but needs two workarounds, set in the
session environment:

- `KWIN_FORCE_SW_CURSOR=1`: the vendor `sunxi-drm` cursor plane shows garbage
  (a tiny cursor in a corner plus a stretched black bar). A software cursor is
  fine. wlroots compositors have the same switch: `WLR_NO_HARDWARE_CURSORS=1`.
- `KWIN_USE_BUFFER_AGE=0`: with zink the EGL buffer age KWin gets does not match
  the buffer contents, so partial repaints leave stale areas (a selection
  rectangle stays on screen for seconds). Disabling it fixes the artefacts but
  every frame is then repainted in full, which costs FPS at high resolutions.
  The proper fix (buffer age through zink/PowerVR WSI) is not done.

Animations are noticeably slow at 3440x1440. KDE is not part of the images
built here; sway is.

## Wi-Fi (AIC8800, WPA3)

The Zero 3W's AIC8800D80 (`aic8800_fdrv`, FullMAC) does WPA3-Personal: SAE runs
in `wpa_supplicant` through cfg80211 external auth (`iw phy` shows "Device
supports SAE with AUTHENTICATE command"), PMF with BIP-CMAC-128 works. Verified
against a WPA3-only (SAE, CCMP-128, MFP required) Wi-Fi 6 AP: HE 80 MHz,
540/360 Mbit/s link rate. The often-quoted "no 256-bit ciphers" limitation only
matters for WPA3-Enterprise 192-bit.

On Armbian trixie a WPA3-only network added through netplan fails in two ways:

- `key-management: psk` (the default, also what `armbian-config` writes) makes a
  WPA2-PSK profile that a WPA3-only AP never accepts. Use `key-management: sae`.
- netplan 1.1.2 then writes `pmf=2` (optional) into the NetworkManager profile,
  which NetworkManager 1.52 rejects for SAE ("pmf can only be 'default' or
  'required' when using 'owe', 'sae' ..."), so the profile silently does not
  appear in `nmcli con show`. netplan 1.1.2 has no `pmf-mode` key; pass the
  value through instead:

```yaml
      access-points:
        "MyWPA3Network":
          networkmanager:
            passthrough:
              wifi-security.pmf: "3"
          auth:
            key-management: sae
            password: "the password, on one line, quoted"
```

Then `sudo netplan apply`. Keep the password on one line and quoted: YAML
folds an indented continuation line into the value with a space, and `#` or
`: ` change its meaning.

In the `wpa_supplicant` debug log, `SME: SAE authentication transaction 2
status code 15` (challenge failure, after a successful commit exchange) means
the password does not match the AP's; NetworkManager reports it as "Secrets
were required, but not provided".

## Building on WSL2

- Armbian refuses to run as root and needs a TTY for `EXPERT=yes`: build as a
  normal user with passwordless sudo, without `EXPERT`.
- With Docker Desktop's WSL integration present but unusable by the build user,
  pass `-- PREFER_DOCKER=no`.
- `arch-test arm64` fails after a WSL restart because `binfmt_misc`
  registrations are lost: re-register the qemu binfmt entries
  (`systemd-binfmt` or `update-binfmts --enable`) before each build, for
  example from `boot.command` in `/etc/wsl.conf`.
