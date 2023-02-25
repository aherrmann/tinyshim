load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

http_archive(
    name = "rules_zig",
    auth_patterns = {"github.com": "Bearer <password>"},
    sha256 = "5c281d16dea00761fa8ec90c576511a1bad9258af9737a9f560de127f7f7147f",
    strip_prefix = "rules_zig-7e0b6d4a9c85fb20fedc6c2a5e90bcd6c490790d",
    url = "https://github.com/aherrmann/rules_zig/archive/7e0b6d4a9c85fb20fedc6c2a5e90bcd6c490790d.tar.gz",
)

load("@rules_zig//zig:repositories.bzl", "rules_zig_dependencies", "zig_register_toolchains")

rules_zig_dependencies()

zig_register_toolchains(
    name = "zig",
    zig_version = "0.10.1",
)
