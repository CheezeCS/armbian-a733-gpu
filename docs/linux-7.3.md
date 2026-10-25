# "BXM-4-64 supported in Linux 7.3": what it means for A733

Linux 7.3 includes commit
[`e55fead22ff9`](https://github.com/torvalds/linux/commit/e55fead22ff9),
"drm/imagination: promote BXM-4-64 MC1 (36.52.104.182) to supported status".
It moves one entry in `pvr_gpu_support_level()` from *experimental* to
*supported*.

`36.52.104.182` is the BXM-4-64 in the **T-Head TH1520** (RISC-V). The A733 has
**`36.56.104.183`**, a different revision. In upstream 7.3 this BVNC is still
unknown: the upstream driver refuses to bind with "Unknown GPU" unless loaded
with `exp_hw_support=1`. Mainline also lacks the A733 device-tree, clock and
power-domain support needed to describe the GPU. There is nothing to backport
for A733 *support*: apercel already carries the upstream driver without the
BVNC gate.

## What was backported instead: upstream bug fixes

apercel is based on an upstream snapshot from around mid-2025, adapted to
kernel 6.6. The fork [CheezeCS/apercel](https://github.com/CheezeCS/apercel) carries **30 later upstream
`drm/imagination` fixes** plus 3 small adaptations (branch `upstream-fixes`,
also on `main`, which `build.sh` builds). The commits keep the original
authors and commit messages, with a `(cherry picked from commit ...)` trailer
and an `[apercel: ...]` note where the code had to be adapted.

| Area | Upstream commits |
|---|---|
| GPU reset and interrupts | `a55c2a5c8d68` deadlock in soft reset; `74ef7844dd8c`, `2d7f05cddf4c` disable/synchronise IRQs before suspend |
| Paired geometry/fragment jobs | `9cd74f935306`, `5dae1a21f1e7`, `c162e655092d`, `18998b3cb759`, `4baf9e70cb75`, `62a36c2da774`, `5c81eb297013`, `402562e60c6c` |
| Timeouts | `ee7cb7425314` no timeout for an already signalled job; `2224d6642136` scheduler timeout (60 s) above the FW timeout (30 s) instead of 0.5 s |
| FW context reset | `d994acc526c7` handle reset notifications (+ `pvr_dump.c`), `d2f83a6cd598`, `da173557a2b0`, `de1e8a590f4e` |
| Memory / VM / MMU | `789f290b2e81` page-table preallocation (could underflow and OOM-panic), `0a8224058a58`, `196d4d10c1b3` GEM ref leak and wrong vm_bo in remap, `7b824c293a6b`, `17e2030f3760`, `45585c3aa285` clamp FW freelist requests, `bccc174bdf1a` |
| ioctl / misc | `d431b4012fd2`, `8dc8f3f4c238`, `cf385cf6e713`, `4af24c27a39b`, `6b991ad8dc3a`, `c7384288d926` |

Local adaptations:

- `DRM_GPU_SCHED_STAT_NO_HANG` only exists from 6.17. On older kernels the
  scheduler has already taken the job off the pending list when it calls
  `timedout_job()`, so the driver puts it back itself (what the newer core does
  for `NO_HANG`) and returns `NOMINAL`.
- `pvr_dump.o` added to apercel's `Makefile`.
- `drm_driver.date` set for kernels before 6.14 (removes the `drm_copy_field`
  WARN on the first `DRM_IOCTL_VERSION`).

Verification: every backported commit changes the same lines as the upstream
original, except the four places adapted for 6.6 and apercel's vendored GPUVM
(`drm_gpuva_link_img()`). Tested on an Orange Pi Zero 3W: module load, Vulkan
compute, sway + vkcube + Vesktop, no kernel warnings, timeouts or resets.

Not backported: `144d47f90536` (not applicable: it fixes a regression from
`e19cc5ab347e3`, the switch to `dev_pm_domain_attach_list()`, which apercel
does not have; apercel's older `pvr_power_domains_init()` is fine with the
single power domain of the A733 GPU, since `pvr_device` is zero-allocated and
the matching fini is a no-op), refactors, RISC-V/TH1520 and other SoC support,
and changes tied to newer DRM core APIs.

These belong in apercel itself; `upstream-fixes` is ready to be proposed
there.
