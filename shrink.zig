const clap = @import("clap");
const std = @import("std");

const debug = std.debug;
const io = std.io;

const Args = struct {
    const exe_name = "shrink";
    const params = clap.parseParamsComptime(
        \\-h, --help   Display this help and exit.
        \\<FILE>       The ELF file to shrink.
        \\
    );
    const parsers = .{
        .FILE = clap.parsers.string,
    };

    diag: clap.Diagnostic,
    res: clap.Result(clap.Help, &params, parsers),

    elf_file: []const u8,

    fn usage() !void {
        try io.getStdErr().writer().print("{s} ", .{exe_name});
        try clap.usage(io.getStdErr().writer(), clap.Help, &params);
        try io.getStdErr().writeAll("\n\n");
    }

    pub fn parse() !?Args {
        var diag = clap.Diagnostic{};
        var res = clap.parse(clap.Help, &params, parsers, .{
            .diagnostic = &diag,
        }) catch |err| {
            diag.report(io.getStdErr().writer(), err) catch {};
            usage() catch {};
            return err;
        };
        if (res.args.help) {
            try usage();
            try clap.help(io.getStdErr().writer(), clap.Help, &params, .{});
            return null;
        }
        if (res.positionals.len < 1) {
            try io.getStdErr().writeAll("Missing positional argument\n\n");
            try usage();
            return error.MissingArgument;
        }
        const elf_file = res.positionals[0];
        return Args{
            .diag = diag,
            .res = res,
            .elf_file = elf_file,
        };
    }

    pub fn deinit(self: *Args) void {
        self.res.deinit();
    }
};

pub fn main() !void {
    var args = (try Args.parse()) orelse return;
    defer args.deinit();
    debug.print("{s}\n", .{args.elf_file});
}
