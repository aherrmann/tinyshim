load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

http_archive(
    name = "rules_zig",
    sha256 = "f6028552467fa8d0b3ab56d7a73c3a0b979cf36d980c14b5764fa16e2a869b3c",
    strip_prefix = "rules_zig-8692fc865d4f65c5b6eba9d316686c166b3f5f67",
    url = "https://github.com/aherrmann/rules_zig/archive/8692fc865d4f65c5b6eba9d316686c166b3f5f67.tar.gz",
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
