# HDMI: "no signal" after boot or cable re-plug

## Symptom

With the Orange Pi vendor 6.6 kernel (`sun60iw2`), the HDMI monitor shows the
console for a moment or not at all, reports **no signal** and switches to another
input. Re-plugging the cable does not help. The kernel thinks everything is fine:
`/sys/class/drm/card0-HDMI-A-1/status` is `connected`, the CRTC is active and
the console is bound to the framebuffer.

This is not related to the GPU driver: display output is handled by the vendor
`sunxi-drm` driver (`card0`); the PowerVR GPU (`card1`, `renderD128`) only
renders.

## What is actually happening

1. At boot, `sunxi_drm_mode_monitor_work_handler()` (`bsp/drivers/drm/sunxi_drm_drv.c`)
   picks the **first EDID mode** (the monitor's native one) and enables the
   output once. It ignores the `video=` kernel parameter.
2. Many monitors **drop HPD by themselves** about 30 seconds later while hunting
   for an active input, then raise it again. Unplugging the cable does the same.
3. On HPD loss, `_sunxi_drv_hdmi_hpd_plugout()` (`sunxi_drm_hdmi.c`) powers the TMDS
   output down (`sunxi_hdmi_disconfig()`), but the DRM CRTC/connector state stays
   **active**.
4. On HPD return, `_sunxi_drv_hdmi_hpd_plugin()` only re-reads the EDID. Nobody
   enables the output again, because as far as DRM is concerned it is on. The
   hook that would let fbdev react to hot-plug (`output_poll_changed`) is
   commented out in this tree.

A full modeset (anything that disables and re-enables the CRTC) brings the
picture back.

### Things that turned out not to matter

- **The mode.** 3440x1440@60 (319.75 MHz pixel clock, no CEA VIC) works,
  verified with `modetest`. 1920x1080 and 2560x1440 work as well.
- **The PHY warning.** `snps phy check clk: 319750Hz is match in [297000Hz-330000Hz]
  and change use: 330000Hz` refers to the PHY MPLL parameter table, not to the
  pixel clock (the TCON and top PHY are set to exactly 319.75 MHz). For 8-bit
  colour the 297 MHz and 330 MHz rows of `sun60i_mpll_rep0` are identical, and
  the PHY reports `lock`.
- **`video=HDMI-A-1:...`** on the kernel command line is parsed by DRM (it shows
  up as a `userdef` mode) but the vendor driver never consults it.

## Fix: kernel patch 0012 (verified)

`armbian/userpatches/kernel/archive/sun60iw2-opi-vendor/0012-sunxi-hdmi-restore-output-after-hpd-replug.patch`,
applied to every kernel built by `build.sh`: after an HPD plug-in, if the CRTC
driving the HDMI connector is still active while the HDMI driver has been
disabled, commit that CRTC with `connectors_changed` set, i.e. a full disable +
mode_set + enable (what `drm_atomic_helper_reset_crtc()` does in newer kernels).

Verified on an Orange Pi Zero 3W with a 3440x1440 monitor: the console is there
after boot, and after a cable re-plug the kernel logs

```text
sunxi-hdmi: hdmi drv detect hpd disconnect
sunxi-hdmi: hdmi drv detect hpd connect
sunxi-hdmi: drm hdmi atomic disable done
sunxi-hdmi: hdmi drv enable output done
sunxi-hdmi: hdmi drv restore output after hpd plugin
```

and the picture is back about half a second after the monitor returns. A
compositor (sway) on top is unaffected.

## Workaround for the stock kernel

`files/hdmi-fix/` restores the output from user space and is meant for systems
that run a kernel without patch 0012 (images built here do not install it):

- `99-hdmi-console-restore.rules`: on every DRM hot-plug uevent from `sunxi-drm`,
  starts
- `hdmi-console-restore.service` (also run once at boot), which runs
- `hdmi-console-restore`: waits 3 s for HPD to settle, finds the connected HDMI
  connector, sets DPMS off/on with `modetest` (a full modeset) and rebinds fbcon
  to the framebuffer. Rate-limited to once per 10 s. When a compositor holds DRM
  master, setting DPMS fails and the script does nothing.

Needs `modetest` (Debian package `libdrm-tests`). Verified on the same board.

```bash
sudo apt install libdrm-tests
sudo install -m 755 files/hdmi-fix/hdmi-console-restore /usr/local/sbin/
sudo install -m 644 files/hdmi-fix/hdmi-console-restore.service /etc/systemd/system/
sudo install -m 644 files/hdmi-fix/99-hdmi-console-restore.rules /etc/udev/rules.d/
sudo systemctl daemon-reload && sudo systemctl enable --now hdmi-console-restore.service
sudo udevadm control --reload-rules
```

## Testing tips

- `modetest -M sunxi-drm -c` lists connectors and modes (`#index`).
- Show a test pattern with an explicit plane (legacy mode-setting does not attach
  one on this driver, which gives a black screen *with* signal):
  `sleep 60 | sudo modetest -M sunxi-drm -a -s <connector>@<crtc>:#<mode> -P <plane>@<crtc>:WxH`.
  `modetest` waits for a key press; when backgrounded it exits immediately unless
  stdin stays open, hence the `sleep` pipe.
- `/sys/kernel/debug/dri/0/state` shows the CRTC, plane and mode actually in use.
