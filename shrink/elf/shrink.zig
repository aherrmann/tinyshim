const clap = @import("clap");
const std = @import("std");
const elf_util = @import("elf_util");

const Args = struct {
    const exe_name = "shrink";
    const params = clap.parseParamsComptime(
        \\-h, --help   Display this help and exit.
        \\<FILE>       The ELF file to shrink.
        \\<PATH>       Where to store the shrunk ELF file.
        \\<STRING>     Delete sections starting from this section.
        \\
    );
    const parsers = .{
        .FILE = clap.parsers.string,
        .PATH = clap.parsers.string,
        .STRING = clap.parsers.string,
    };

    diag: clap.Diagnostic,
    res: clap.Result(clap.Help, &params, parsers),

    elf_file: []const u8,
    out_path: []const u8,
    last_section: []const u8,

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
        if (res.positionals.len < 3) {
            try std.io.getStdErr().writeAll("Missing positional argument\n\n");
            try usage();
            return error.MissingArgument;
        }
        const elf_file = res.positionals[0];
        const out_path = res.positionals[1];
        const last_section = res.positionals[2];
        return Args{
            .diag = diag,
            .res = res,
            .elf_file = elf_file,
            .out_path = out_path,
            .last_section = last_section,
        };
    }

    pub fn deinit(self: *Args) void {
        self.res.deinit();
    }
};

/// Shrinks an ELF file by removing all section headers and sections from a specified section,
/// and writes the result to a new file.
/// This function takes an `allocator` for temporary memory allocation, `input_path` as the
/// path to the input ELF file, `output_path` as the path to the output ELF file, and
/// `target_section_name` as the name of the target section to delete from.
/// If the target section is not found, an error is returned.
fn shrink(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    output_path: []const u8,
    target_section_name: []const u8,
) !void {
    const input_file = try std.fs.cwd().openFile(input_path, .{});
    defer input_file.close();

    const modified_data = try elf_util.dropSectionsFromTarget(allocator, input_file, target_section_name);
    defer allocator.free(modified_data);

    const output_file = try std.fs.cwd().createFile(output_path, .{});
    defer output_file.close();

    try output_file.writeAll(modified_data);
}

pub fn main() !void {
    var args = (try Args.parse()) orelse return;
    defer args.deinit();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try shrink(allocator, args.elf_file, args.out_path, args.last_section);
}
