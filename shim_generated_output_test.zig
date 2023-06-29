const std = @import("std");

const TestArgs = struct {
    mkshim: []const u8,

    pub fn init() !TestArgs {
        const allocator = std.testing.allocator;

        const args = try std.process.argsAlloc(allocator);
        defer allocator.free(args);

        if (args.len != 2) {
            std.debug.print("\nMissing argument <mkshim>\n", .{});
            return error.MissingArgument;
        }

        return .{
            .mkshim = try allocator.dupe(u8, args[1]),
        };
    }

    pub fn deinit(self: TestArgs) void {
        const allocator = std.testing.allocator;

        allocator.free(self.mkshim);
    }
};

const TmpDir = struct {
    dir: std.testing.TmpDir,
    path: []const u8,

    pub fn init() !TmpDir {
        const allocator = std.testing.allocator;

        var tmp_dir = std.testing.tmpDir(.{});
        const tmp_path = try tmp_dir.parent_dir.realpathAlloc(allocator, &tmp_dir.sub_path);

        return .{
            .dir = tmp_dir,
            .path = tmp_path,
        };
    }

    pub fn deinit(self: *TmpDir) void {
        defer std.testing.allocator.free(self.path);
        defer self.dir.cleanup();
    }
};

test "mkshim generated shim invokes /bin/echo Hello $@" {
    const test_args = try TestArgs.init();
    defer test_args.deinit();

    var tmp = try TmpDir.init();
    defer tmp.deinit();

    const allocator = std.testing.allocator;

    const shim_path = try std.fs.path.join(allocator, &[_][]const u8{ tmp.path, "shim" });
    defer allocator.free(shim_path);

    const mkshim_result = try std.ChildProcess.exec(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            test_args.mkshim,
            "/bin/echo",
            "--prepend",
            "Hello",
            shim_path,
        },
    });
    defer allocator.free(mkshim_result.stdout);
    defer allocator.free(mkshim_result.stderr);

    std.testing.expectEqual(std.ChildProcess.Term{ .Exited = 0 }, mkshim_result.term) catch |e| {
        std.debug.print("\nmkshim failed ({})\nstdout: {s}\nstderr: {s}\n", .{
            mkshim_result.term,
            mkshim_result.stdout,
            mkshim_result.stderr,
        });
        return e;
    };

    const result = try std.ChildProcess.exec(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            shim_path,
            "World!",
        },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    std.testing.expectEqual(std.ChildProcess.Term{ .Exited = 0 }, result.term) catch |e| {
        std.debug.print("\nshim failed ({})\nstdout: {s}\nstderr: {s}\n", .{
            result.term,
            result.stdout,
            result.stderr,
        });
        return e;
    };
    try std.testing.expectEqualStrings("Hello World!\n", result.stdout);
}

test "mkshim can target aarch64-linux" {
    const test_args = try TestArgs.init();
    defer test_args.deinit();

    var tmp = try TmpDir.init();
    defer tmp.deinit();

    const allocator = std.testing.allocator;

    const shim_path = try std.fs.path.join(allocator, &[_][]const u8{ tmp.path, "shim" });
    defer allocator.free(shim_path);

    const mkshim_result = try std.ChildProcess.exec(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            test_args.mkshim,
            "--target",
            "aarch64-linux",
            "/bin/echo",
            "--prepend",
            "Hello",
            shim_path,
        },
    });
    defer allocator.free(mkshim_result.stdout);
    defer allocator.free(mkshim_result.stderr);

    std.testing.expectEqual(std.ChildProcess.Term{ .Exited = 0 }, mkshim_result.term) catch |e| {
        std.debug.print("\nmkshim failed ({})\nstdout: {s}\nstderr: {s}\n", .{
            mkshim_result.term,
            mkshim_result.stdout,
            mkshim_result.stderr,
        });
        return e;
    };

    // TODO[AH] Infer emulation based on host and target platforms.
    // TODO[AH] Include emulator in a more hermetic way.
    //   At least as a toolchain discovered in a repository rule.
    //   Potentially as a Bazel fetched or built distribution.
    const result = try std.ChildProcess.exec(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            "qemu-aarch64",
            shim_path,
            "World!",
        },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    std.testing.expectEqual(std.ChildProcess.Term{ .Exited = 0 }, result.term) catch |e| {
        std.debug.print("\nshim failed ({})\nstdout: {s}\nstderr: {s}\n", .{
            result.term,
            result.stdout,
            result.stderr,
        });
        return e;
    };
    try std.testing.expectEqualStrings("Hello World!\n", result.stdout);
}
