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
    sha256 = "07c426248a729fbd443d3cc42c70c6bcf5bd2a18cf6a08ab9097f31a397a374f",
    strip_prefix = "zig-clap-0.6.0",
    url = "https://github.com/Hejsil/zig-clap/archive/refs/tags/0.6.0.tar.gz",
)
