load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

http_archive(
    name = "rules_zig",
    auth_patterns = {"github.com": "Bearer <password>"},
    sha256 = "21c56d85a34f43f5ae446b20194571c25172b3f0f7fd05c4a9b816f372fa740e",
    strip_prefix = "rules_zig-6262b4372bd39cc303246656f9fb72eb441ed0e8",
    url = "https://github.com/aherrmann/rules_zig/archive/6262b4372bd39cc303246656f9fb72eb441ed0e8.tar.gz",
)

load("@rules_zig//zig:repositories.bzl", "rules_zig_dependencies", "zig_register_toolchains")

rules_zig_dependencies()

zig_register_toolchains(
    name = "zig",
    zig_version = "0.10.1",
)
