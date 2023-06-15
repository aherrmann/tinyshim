load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

http_archive(
    name = "rules_zig",
    sha256 = "14401b13b87a5c3eabaad10c5c32f81cd4216344556dc7065211f256754bdd7e",
    strip_prefix = "rules_zig-da4031aa75b1d496a32688a42890cce6870c83d7",
    url = "https://github.com/aherrmann/rules_zig/archive/da4031aa75b1d496a32688a42890cce6870c83d7.tar.gz",
)

load("@rules_zig//zig:repositories.bzl", "rules_zig_dependencies", "zig_register_toolchains")

rules_zig_dependencies()

zig_register_toolchains(
    name = "zig",
    zig_version = "0.10.1",
)

http_archive(
    name = "clap",
    build_file_content = """\
load("@rules_zig//zig:defs.bzl", "zig_package")
zig_package(
    name = "clap",
    main = "clap.zig",
    srcs = glob(["clap/**/*.zig"]),
    visibility = ["//visibility:public"],
)
""",
    # TODO[AH] remove once https://github.com/Hejsil/zig-clap/pull/97 is merged.
    patch_args = ["-p1"],
    patches = ["//patches/zig-clap:multiple-positional-parameters.patch"],
    sha256 = "07c426248a729fbd443d3cc42c70c6bcf5bd2a18cf6a08ab9097f31a397a374f",
    strip_prefix = "zig-clap-0.6.0",
    url = "https://github.com/Hejsil/zig-clap/archive/refs/tags/0.6.0.tar.gz",
)
