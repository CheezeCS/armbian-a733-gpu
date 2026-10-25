# apercel Mesa patch ported to Mesa 26.3

`mesa/apercel-mesa-26.3.0-rc2.patch` in [CheezeCS/apercel](https://github.com/CheezeCS/apercel) (branch
`mesa-26.3`, also on `main`) is the
[apercel](https://github.com/TumRedSun/apercel) Mesa patch (written against
vanilla 26.1.8) carried over to **Mesa 26.3.0-rc2**, the first release branch
with `VK_EXT_transform_feedback` for PowerVR
([mesa!44385](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/44385)).

## Result

| | Mesa 26.1.8 + apercel | Mesa 26.3.0-rc2 + apercel |
|---|---|---|
| `VK_EXT_transform_feedback` | no | yes (1 stream, 4 buffers) |
| GLES via zink | 2.0 | **3.1** (GLSL ES 3.10) |
| Desktop GL via zink | 2.1 | **3.2 core** (GLSL 1.50) |
| Vulkan compute (`tools/vktest`) | OK | OK |
| `vkcube --wsi wayland` | OK | OK |
| Electron GPU without flags | no | yes |

## How it was ported

A three-way merge in git: vanilla 26.1.8 → apercel commit, then that commit
cherry-picked onto vanilla 26.3.0-rc2. Most hunks applied as-is; eight files
conflicted and were resolved as follows.

| File | Resolution |
|---|---|
| `pco/meson.build` | keep upstream's new `pco_nir_alu.c` and apercel's `pco_nir_16bit_io.c` |
| `pco/pco_internal.h` | upstream's new `pco_nir_lower_io(shader, data)` signature and helpers, plus apercel's `pco_nir_lower_16bit_io()` |
| `pco/pco_nir.c` | upstream's new `lower_uadd_carry` / `lower_usub_borrow` options with apercel's `max_unroll_iterations = 1024`; apercel's push-constant bit-size lowering before upstream's `nir_lower_robust_access(..., &data->common)` and shared-memory spilling |
| `pco/pco_nir_pvfio.c` | upstream rewrote `lower_pvi()` as an intrinsics pass; apercel's out-of-range vertex attribute guard moved into the new function |
| `vulkan/pvr_arch_device.c` | upstream's `pvr_device_dummy_rt_finish()` plus apercel's render-state and load-op cache teardown |
| `vulkan/pvr_arch_pipeline.c` | upstream's new robustness / null-descriptor / image-view fields plus apercel's comment |
| `vulkan/pvr_device.h` | upstream's tracing data source plus apercel's cache fields |
| `vulkan/pvr_physical_device.c` | features: union of both sides (upstream: `fragmentStoresAndAtomics`, `transformFeedback`, workgroup explicit layout; apercel: `vertexPipelineStoresAndAtomics`, `bufferDeviceAddress`, `shaderZeroInitializeWorkgroupMemory`, `pipelineCreationCacheControl`, `robustImageAccess`); descriptor limits: apercel's values (upstream left them unchanged); upstream's `get_supported_extensions(..., instance)` signature |

Two follow-up commits:

- `include/drm-uapi/pvr_drm.h`: `#define DRM_PVR_BO_CPU_CACHED 0`. The apercel
  Mesa patch uses this flag, but neither Mesa's UAPI header nor the apercel
  kernel module defines it (the module accepts only BO flag bits 0-2), so it
  becomes a no-op and `HOST_CACHED` memory stays write-combined. The fork adds
  the same definition to the 26.1.8 patch, which did not build without it.
- `vulkan/pvr_device.c`: `vk_foreach_struct_const()` takes three arguments in
  26.3; the apercel `PVR_API_TRACE` debug code was adapted.

## Caveats

- Mesa 26.3.0-rc2 is a release candidate. Rebase when 26.3.0 is out.
- PowerVR advertises `transformFeedbackQueries = false`; GL queries of written
  primitive counts through zink may misbehave. Chromium and the tested apps do
  not use them.
- Only lightly tested: device enumeration, compute, Wayland WSI, Electron. No
  conformance runs. Report regressions against 26.1.8 with
  `sudo a733-build-mesa --mesa 26.1.8` as the baseline.

## Build dependencies on Debian trixie

apercel's README targets Gentoo with `-Dmesa-clc=system -Dllvm=disabled`. Debian
has no `mesa_clc` package, and the PowerVR driver compiles its internal shaders
with `mesa-clc` at build time, so LLVM must be enabled (`-Dllvm=enabled
-Dmesa-clc=enabled`) with one consistent LLVM major (19 on trixie):
`clang libclang-cpp-dev libclang-19-dev llvm-19-dev libllvmspirvlib-19-dev
spirv-tools` (the SPIRV-Tools development files are in `spirv-tools`), plus
`libwayland-egl-backend-dev` and the X11 development libraries for
`-Dplatforms=x11,wayland`. `a733-build-mesa` installs all of them.
