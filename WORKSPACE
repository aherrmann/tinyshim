load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

http_archive(
    name = "rules_zig",
    sha256 = "b59a08f35b2589f290b72ccc1e83002577a6e76951a5260981852f22736c4523",
    strip_prefix = "rules_zig-f2347a0398b252bc876d246467a4d691ccdc9bac",
    url = "https://github.com/aherrmann/rules_zig/archive/f2347a0398b252bc876d246467a4d691ccdc9bac.tar.gz",
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

http_archive(
    name = "aspect_bazel_lib",
    sha256 = "e3151d87910f69cf1fc88755392d7c878034a69d6499b287bcfc00b1cf9bb415",
    strip_prefix = "bazel-lib-1.32.1",
    url = "https://github.com/aspect-build/bazel-lib/releases/download/v1.32.1/bazel-lib-v1.32.1.tar.gz",
)

load("@aspect_bazel_lib//lib:repositories.bzl", "aspect_bazel_lib_dependencies")

aspect_bazel_lib_dependencies()
