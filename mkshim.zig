const builtin = @import("builtin");
const clap = @import("clap");
const std = @import("std");
const shim_templates = @import("shim_templates");
const Payload = @import("payload.zig").Payload;

const Args = struct {
    const exe_name = "mkshim";
    const params = clap.parseParamsComptime(
        \\-h, --help   Display this help and exit.
        \\<PATH>       Where to create the generated shim.
        \\
    );
    const parsers = .{
        .PATH = clap.parsers.string,
    };

    diag: clap.Diagnostic,
    res: clap.Result(clap.Help, &params, parsers),

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
            return null;
        }
        if (res.positionals.len < 1) {
            try std.io.getStdErr().writeAll("Missing positional argument\n\n");
            try usage();
            return error.MissingArgument;
        }
        const out_path = res.positionals[0];
        return Args{
            .diag = diag,
            .res = res,
            .out_path = out_path,
        };
    }

    pub fn deinit(self: *Args) void {
        self.res.deinit();
    }
};

fn payloadSize(payload: Payload) usize {
    const pointer_align = @alignOf(*u8);
    const pointer_size = @alignOf(*u8);
    var result: usize = 0;

    // Payload struct
    result += std.mem.alignForward(@sizeOf(Payload), pointer_align);

    // argv_pre pointer array
    result += payload.argc_pre * pointer_size;

    // exec string
    result += std.mem.sliceTo(payload.exec, 0).len + 1;

    // argv_pre string values
    for (payload.argv_pre[0..payload.argc_pre]) |arg| {
        result += std.mem.sliceTo(arg, 0).len + 1;
    }
    result = std.mem.alignForward(result, pointer_align);

    return result;
}

test "payloadSize on empty payload" {
    const payload = Payload{
        .exec = "",
        .argc_pre = 0,
        .argv_pre = &[_][*:0]const u8{},
    };

    const expectedSize = std.mem.alignForward(@sizeOf(Payload) + 1, @alignOf(*u8));
    try std.testing.expectEqual(expectedSize, payloadSize(payload));
}

test "payloadSize on non-empty payload" {
    const payload = Payload{
        .exec = "/bin/echo",
        .argc_pre = 2,
        .argv_pre = &[_][*:0]const u8{ "Hello", "World!\n" },
    };

    const expectedSize = std.mem.alignForward(@sizeOf(Payload) + 2 * @sizeOf(*u8) + 10 + 6 + 8, @alignOf(*u8));
    try std.testing.expectEqual(expectedSize, payloadSize(payload));
}

pub fn main() !void {
    var args = (try Args.parse()) orelse return;
    defer args.deinit();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    _ = allocator;

    try std.io.getStdOut().writer().print("Creating shim at {s}\n", .{args.out_path});
    try std.io.getStdOut().writer().print("Size of template {}\n", .{shim_templates.shim_template.len});
}
