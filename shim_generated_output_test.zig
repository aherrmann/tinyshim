const std = @import("std");

test "mkshim generated shim invokes /bin/echo Hello $@" {
    const allocator = std.testing.allocator;

    const args = try std.process.argsAlloc(allocator);
    defer allocator.free(args);

    try std.testing.expectEqual(@as(usize, 2), args.len);
    const mkshim_path = args[1];

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.parent_dir.realpathAlloc(allocator, &tmp_dir.sub_path);
    defer allocator.free(tmp_path);

    const shim_path = try std.fs.path.join(allocator, &[_][]const u8{ tmp_path, "shim" });
    defer allocator.free(shim_path);

    const mkshim_result = try std.ChildProcess.exec(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            mkshim_path,
            "/bin/echo",
            "--prepend",
            "Hello",
            shim_path,
        },
    });
    defer allocator.free(mkshim_result.stdout);
    defer allocator.free(mkshim_result.stderr);

    try std.testing.expectEqual(std.ChildProcess.Term{ .Exited = 0 }, mkshim_result.term);

    const result = try std.ChildProcess.exec(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            shim_path,
            "World!",
        },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.ChildProcess.Term{ .Exited = 0 }, result.term);
    try std.testing.expectEqualStrings("Hello World!\n", result.stdout);
}
