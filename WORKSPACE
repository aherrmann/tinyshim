load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

http_archive(
    name = "rules_zig",
    auth_patterns = {"github.com": "Bearer <password>"},
    sha256 = "f09f397729072f1a7c76fa0ab8c0167d07fb7564e82d9565882ddb2c5506eff8",
    strip_prefix = "rules_zig-185b22ca077f4c6410e6b287a01dd4126af58ce8",
    url = "https://github.com/aherrmann/rules_zig/archive/185b22ca077f4c6410e6b287a01dd4126af58ce8.tar.gz",
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
    patch_args = ["-p1"],
    patches = ["//patches/zig-clap:multiple-positional-parameters.patch"],
    sha256 = "07c426248a729fbd443d3cc42c70c6bcf5bd2a18cf6a08ab9097f31a397a374f",
    strip_prefix = "zig-clap-0.6.0",
    url = "https://github.com/Hejsil/zig-clap/archive/refs/tags/0.6.0.tar.gz",
)
