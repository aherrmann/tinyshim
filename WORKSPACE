load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

http_archive(
    name = "rules_zig",
    sha256 = "0000000000000000000000000000000000000000000000000000000000000000",
    url = "https://github.com/aherrmann/rules_zig/releases/download/0.1.0/rules_zig-0.1.0.tar.gz",
)

load("@rules_zig//zig:repositories.bzl", "rules_zig_dependencies", "zig_register_toolchains")

rules_zig_dependencies()

zig_register_toolchains(
    name = "zig",
    zig_version = "0.10.1",
)
