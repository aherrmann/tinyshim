const builtin = @import("builtin");
const clap = @import("clap");
const std = @import("std");
const shim_templates = @import("shim_templates");
const Payload = @import("payload").Payload;
const generate_shim = @import("generate_shim");

const native_target = @tagName(builtin.target.cpu.arch) ++ "-" ++ @tagName(builtin.target.os.tag);
const native_endian = builtin.cpu.arch.endian();

const supported_targets = supported: {
    var size = 0;
    for (shim_templates.shim_templates.kvs) |kv| {
        size += "  ".len + kv.key.len + "\n".len;
    }
    var result: [size]u8 = undefined;
    var offset: usize = 0;
    for (shim_templates.shim_templates.kvs) |kv| {
        std.mem.copy(u8, result[offset..], "  " ++ kv.key ++ "\n");
        offset += "  ".len + kv.key.len + "\n".len;
    }
    break :supported result;
};

const Args = struct {
    const exe_name = "mkshim";
    const params = clap.parseParamsComptime(
        \\-h, --help   Display this help and exit.
        \\--target <STRING>      Create a shim for this target platform.
        \\--prepend <STRING>...  Prepend arguments on the command-line.
        \\<PATH>                 Execute this target executable.
        \\<PATH>                 Where to create the generated shim.
        \\
    );
    const parsers = .{
        .PATH = clap.parsers.string,
        .STRING = clap.parsers.string,
    };

    diag: clap.Diagnostic,
    res: clap.Result(clap.Help, &params, parsers),

    shim_template: []const u8,
    argv_pre: []const [*:0]const u8,
    exec: [:0]const u8,
    out_path: []const u8,

    fn usage() !void {
        try std.io.getStdErr().writer().print("{s} ", .{exe_name});
        try clap.usage(std.io.getStdErr().writer(), clap.Help, &params);
        try std.io.getStdErr().writeAll("\n\n");
    }

    pub fn parse() !?Args {
        var diag = clap.Diagnostic{};
        var res = clap.parse(clap.Help, &params, parsers, .{
            .diagnostic = &diag,
        }) catch |err| {
            diag.report(std.io.getStdErr().writer(), err) catch {};
            usage() catch {};
            return err;
        };
        if (res.args.help) {
            try usage();
            try clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{});
            try std.io.getStdErr().writer().print("\nSupported target platforms:\n{s}", .{
                supported_targets,
            });
            return null;
        }
        if (res.positionals.len < 2) {
            try std.io.getStdErr().writeAll("Missing positional arguments\n\n");
            try usage();
            return error.MissingArgument;
        }
        if (res.positionals.len > 2) {
            try std.io.getStdErr().writeAll("Too many positional arguments\n\n");
            try usage();
            return error.MissingArgument;
        }
        var allocator: std.mem.Allocator = res.arena.allocator();
        const target = res.args.target orelse native_target;
        const shim_template = shim_templates.shim_templates.get(target) orelse {
            const msg = "Unsupported target platform {s}\nSupported target platforms:\n{s}";
            try std.io.getStdErr().writer().print(msg, .{
                target,
                supported_targets,
            });
            return error.InvalidArgument;
        };
        var argv_pre = try allocator.alloc([*:0]const u8, res.args.prepend.len);
        for (res.args.prepend) |arg, i| {
            argv_pre[i] = try allocator.dupeZ(u8, arg);
        }
        const exec = try allocator.dupeZ(u8, res.positionals[0]);
        const out_path = try allocator.dupeZ(u8, res.positionals[1]);
        return Args{
            .diag = diag,
            .res = res,
            .shim_template = shim_template,
            .argv_pre = argv_pre,
            .exec = exec,
            .out_path = out_path,
        };
    }

    pub fn deinit(self: *Args) void {
        var allocator: std.mem.Allocator = self.res.arena.allocator();
        for (self.argv_pre) |arg| {
            allocator.free(std.mem.sliceTo(arg, 0));
        }
        allocator.free(self.argv_pre);
        allocator.free(self.exec);
        allocator.free(self.out_path);
        self.res.deinit();
    }
};

pub fn main() !void {
    var args = (try Args.parse()) orelse return;
    defer args.deinit();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // TODO[AH] Replace by generic ShimSpec
    const payload = Payload{
        .exec = args.exec,
        .argc_pre = args.argv_pre.len,
        .argv_pre = args.argv_pre.ptr,
    };

    // Load the shim template and generate the shim.
    const template = args.shim_template;
    const shim = try generate_shim.generateShim(allocator, payload, template);
    defer allocator.free(shim);

    // Write the shim.
    var out_file = try std.fs.cwd().createFile(args.out_path, .{});
    defer out_file.close();
    try out_file.writeAll(shim);

    // Make the shim file executable.
    switch (builtin.os.tag) {
        .windows => {},
        else => {
            const metadata = try out_file.metadata();
            var permissions = metadata.permissions();
            permissions.inner.unixSet(.user, .{ .execute = true });
            permissions.inner.unixSet(.group, .{ .execute = true });
            permissions.inner.unixSet(.other, .{ .execute = true });
            try out_file.setPermissions(permissions);
        },
    }
}