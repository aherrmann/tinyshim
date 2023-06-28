const std = @import("std");

test "shim invokes /bin/echo Hello $@" {
    const allocator = std.testing.allocator;

    const args = try std.process.argsAlloc(allocator);
    defer allocator.free(args);

    try std.testing.expectEqual(@as(usize, 2), args.len);
    const shim_path = args[1];

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
