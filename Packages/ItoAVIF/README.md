# ItoAVIF

Decodes AVIF images on iOS 15, where ImageIO has no AVIF support (it arrived in iOS 16). Ito uses it only for AVIF data on iOS versions before 16; see `Ito/Managers/ItoImageDecoders.swift`.

## Contents

| Target | Source | Version | License |
|---|---|---|---|
| `dav1d` | [dav1d](https://code.videolan.org/videolan/dav1d) | 1.5.4 | BSD-2-Clause (`Sources/dav1d/COPYING`) |
| `libavif` | [libavif](https://github.com/AOMediaCodec/libavif) | 1.4.2 | BSD-2-Clause (`Sources/libavif/LICENSE`) |
| `libavif` (scaling) | libyuv subset bundled by libavif, commit `def473f5` | | BSD-3-Clause (`Sources/libavif/third_party/libyuv/LICENSE`) |
| `ItoAVIF` | Swift wrapper | | Ito's license |

Source archives:

- `dav1d-1.5.4.tar.xz`, SHA-256 `686616b7c69eb88d44459391ab25cac13b6647a3b288835c5784e71c1514a5c5` (matches VideoLAN's published `.sha256`)
- libavif `v1.4.2` tag archive, SHA-256 `2b645287340ba5a631d268b551dc2d72bd73ac33335962dd36dcdb6d8366921d`

## Build configuration

- dav1d is built as portable C: no assembly, both 8- and 16-bit depths, logging off. `Sources/dav1d/config/config.h` replaces the `config.h` that dav1d's meson build generates.
- meson compiles each `src/*_tmpl.c` once per bit depth. `Sources/dav1d/bitdepth/` has one wrapper file per source and depth that defines `BITDEPTH` and includes the template.
- libavif is built with only the dav1d decoder (`AVIF_CODEC_DAV1D=1`). It uses its bundled libyuv subset for scaling.

## Updating

1. Download the new dav1d and libavif releases and verify their checksums.
2. Replace `Sources/dav1d/src`, `Sources/dav1d/include/dav1d` and `Sources/dav1d/include/common` with the release's `src/*.c`, `src/*.h`, `include/dav1d` and `include/common`. Remove `include/dav1d/meson.build`.
3. Compare `libdav1d_sources` and `libdav1d_tmpl_sources` in dav1d's `src/meson.build` with `Package.swift`, and the `cdata.set` keys in its `meson.build` with `config/config.h`. Add a `bitdepth/` wrapper pair for any new template source, and update `config/vcs_version.h`.
4. Replace libavif's `src/*.c` files listed in `Package.swift`, `include/avif/avif.h`, `include/avif/internal.h` and `third_party/libyuv`. Compare `AVIF_SRCS` in its `CMakeLists.txt` with `Package.swift`.
5. Update the versions and hashes in this file, then run `AVIFImageDecodingTests`.
