const std = @import("std");

test "shim prints Hello World!" {
    const allocator = std.testing.allocator;

    const args = try std.process.argsAlloc(allocator);
    defer allocator.free(args);

    try std.testing.expectEqual(@as(usize, 2), args.len);
    const shim_path = args[1];

    // TODO[AH] Infer emulation based on host and target platforms.
    // TODO[AH] Include emulator in a more hermetic way.
    //   At least as a toolchain discovered in a repository rule.
    //   Potentially as a Bazel fetched or built distribution.

    var wineprefix_dir = std.testing.tmpDir(.{});
    defer wineprefix_dir.cleanup();
    const wineprefix = try wineprefix_dir.parent_dir.realpathAlloc(
        allocator,
        &wineprefix_dir.sub_path,
    );
    defer allocator.free(wineprefix);
    var env = std.process.EnvMap.init(allocator);
    defer env.deinit();
    try env.put("WINEPREFIX", wineprefix);
    try env.put("WINEDEBUG", "-all");

    const result = try std.ChildProcess.exec(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            "/usr/bin/wine64",
            shim_path,
            "World!",
        },
        .env_map = &env,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    std.testing.expectEqual(
        std.ChildProcess.Term{ .Exited = 0 },
        result.term,
    ) catch |e| {
        std.debug.print("\nterm: {}\nstdout: {s}\nstderr: {s}\n", .{
            result.term,
            result.stdout,
            result.stderr,
        });
        return e;
    };
    try std.testing.expectEqualStrings("Hello World!\n", result.stdout);
}
