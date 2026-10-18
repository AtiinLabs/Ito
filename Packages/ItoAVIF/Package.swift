// swift-tools-version: 6.2

import PackageDescription

// Vendored dav1d sources compiled by meson's libdav1d_sources list.
let dav1dCoreSources = [
    "cdf", "cpu", "ctx", "data", "decode", "dequant_tables", "getbits", "intra_edge",
    "itx_1d", "lf_mask", "lib", "log", "mem", "msac", "obu", "pal", "picture", "qm",
    "ref", "refmvs", "scan", "tables", "thread_task", "warpmv", "wedge"
].map { "src/\($0).c" }

// meson compiles libdav1d_tmpl_sources once per bit depth; bitdepth/ holds one
// wrapper per (source, depth) pair.
let dav1dTemplateSources = [
    "cdef_apply", "cdef", "fg_apply", "filmgrain", "ipred_prepare", "ipred", "itx",
    "lf_apply", "loopfilter", "looprestoration", "lr_apply", "mc", "recon"
].flatMap { ["bitdepth/\($0)_tmpl_8.c", "bitdepth/\($0)_tmpl_16.c"] }

// libavif's AVIF_SRCS plus the dav1d codec and the libyuv scaling subset that
// libavif builds when an external libyuv is not available.
let libavifSources = [
    "alpha", "avif", "colr", "colrconvert", "diag", "exif", "gainmap", "io", "mem",
    "obu", "properties", "rawdata", "read", "reformat", "reformat_libsharpyuv",
    "reformat_libyuv", "sampletransform", "scale", "stream", "utils", "write",
    "codec_dav1d"
].map { "src/\($0).c" } + [
    "scale", "scale_common", "scale_any", "row_common", "planar_functions"
].map { "third_party/libyuv/source/\($0).c" }

let package = Package(
    name: "ItoAVIF",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "ItoAVIF", targets: ["ItoAVIF"])
    ],
    targets: [
        .target(
            name: "dav1d",
            path: "Sources/dav1d",
            sources: dav1dCoreSources + dav1dTemplateSources,
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
                .headerSearchPath("config"),
                .headerSearchPath("include/dav1d")
            ]
        ),
        .target(
            name: "libavif",
            dependencies: ["dav1d"],
            path: "Sources/libavif",
            sources: libavifSources,
            publicHeadersPath: "include",
            cSettings: [
                .define("AVIF_CODEC_DAV1D", to: "1"),
                .headerSearchPath("third_party/libyuv/include")
            ]
        ),
        .target(
            name: "ItoAVIF",
            dependencies: ["libavif"],
            path: "Sources/ItoAVIF"
        )
    ],
    cLanguageStandard: .c11
)
