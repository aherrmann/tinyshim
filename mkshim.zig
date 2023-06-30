const builtin = @import("builtin");
const clap = @import("clap");
const std = @import("std");
const shim_templates = @import("shim_templates");
const SimpleBumpAllocator = @import("allocator.zig").SimpleBumpAllocator;
const Payload = @import("payload.zig").Payload;

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
        const native_target = @tagName(builtin.target.cpu.arch) ++ "-" ++ @tagName(builtin.target.os.tag);
        const target = res.args.target orelse native_target;
        const shim_template = shim_templates.shim_templates.get(target) orelse {
            try std.io.getStdErr().writer().print("Unsupported target platform {s}\n", .{target});
            // TODO[AH] Print the list of supported target platforms.
            try usage();
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

fn encodePayload(buffer: []u8, offset: usize, payload: Payload) !void {
    var buffer_allocator = SimpleBumpAllocator.init(buffer);

    var encoded_payload = &(try buffer_allocator.alloc(Payload, 1))[0];
    var encoded_argv_pre = try buffer_allocator.alloc([*:0]const u8, payload.argc_pre);
    var encoded_exec = try buffer_allocator.allocSentinel(u8, std.mem.sliceTo(payload.exec, 0).len, 0);

    encoded_payload.exec = @intToPtr([*:0]const u8, @ptrToInt(encoded_exec.ptr) - @ptrToInt(buffer.ptr) + offset);
    encoded_payload.argc_pre = payload.argc_pre;
    encoded_payload.argv_pre = @intToPtr([*]const [*:0]const u8, @ptrToInt(encoded_argv_pre.ptr) - @ptrToInt(buffer.ptr) + offset);

    std.mem.copy(u8, encoded_exec, std.mem.sliceTo(payload.exec, 0));

    for (payload.argv_pre[0..payload.argc_pre]) |arg, i| {
        var encoded_arg = try buffer_allocator.allocSentinel(u8, std.mem.sliceTo(arg, 0).len, 0);
        encoded_argv_pre[i] = @intToPtr([*:0]const u8, @ptrToInt(encoded_arg.ptr) - @ptrToInt(buffer.ptr) + offset);
        std.mem.copy(u8, encoded_arg, std.mem.sliceTo(arg, 0));
    }
}

test "encodePayload on empty payload" {
    const allocator = std.testing.allocator;

    const payload = Payload{
        .exec = "",
        .argc_pre = 0,
        .argv_pre = &[_][*:0]const u8{},
    };

    var buffer = try allocator.alloc(u8, payloadSize(payload));
    defer allocator.free(buffer);

    const offset: usize = 8 * @alignOf(*u8);
    try encodePayload(buffer, offset, payload);

    const exec_offset = @offsetOf(Payload, "exec");
    try std.testing.expectEqualSlices(u8, &std.mem.toBytes(offset + @sizeOf(Payload)), buffer[exec_offset .. exec_offset + @sizeOf(*u8)]);

    const argc_pre_offset = @offsetOf(Payload, "argc_pre");
    try std.testing.expectEqualSlices(u8, &std.mem.toBytes(@as(usize, 0)), buffer[argc_pre_offset .. argc_pre_offset + @sizeOf(usize)]);

    const argv_pre_offset = @offsetOf(Payload, "argv_pre");
    try std.testing.expectEqualSlices(u8, &std.mem.toBytes(offset + @sizeOf(Payload)), buffer[argv_pre_offset .. argv_pre_offset + @sizeOf(*u8)]);

    try std.testing.expectEqualSlices(u8, ""[0..1], buffer[@sizeOf(Payload) .. @sizeOf(Payload) + 1]);
}

test "encodePayload on non-empty payload" {
    const allocator = std.testing.allocator;

    const payload = Payload{
        .exec = "/bin/echo",
        .argc_pre = 2,
        .argv_pre = &[_][*:0]const u8{ "Hello", "World!\n" },
    };

    var buffer = try allocator.alloc(u8, payloadSize(payload));
    defer allocator.free(buffer);

    const offset: usize = 8 * @alignOf(*u8);
    try encodePayload(buffer, offset, payload);

    const exec_offset = @offsetOf(Payload, "exec");
    const exec_value_offset = @sizeOf(Payload) + 2 * @sizeOf(*u8);
    try std.testing.expectEqualSlices(u8, &std.mem.toBytes(offset + exec_value_offset), buffer[exec_offset .. exec_offset + @sizeOf(*u8)]);

    const argc_pre_offset = @offsetOf(Payload, "argc_pre");
    try std.testing.expectEqualSlices(u8, &std.mem.toBytes(@as(usize, 2)), buffer[argc_pre_offset .. argc_pre_offset + @sizeOf(usize)]);

    const argv_pre_offset = @offsetOf(Payload, "argv_pre");
    const argv_pre_array_offset = @sizeOf(Payload);
    try std.testing.expectEqualSlices(u8, &std.mem.toBytes(offset + argv_pre_array_offset), buffer[argv_pre_offset .. argv_pre_offset + @sizeOf(*u8)]);

    try std.testing.expectEqualSlices(u8, "/bin/echo"[0..10], buffer[exec_value_offset .. exec_value_offset + 10]);

    const argv_pre_value_offset = exec_value_offset + 10;
    try std.testing.expectEqualSlices(u8, &std.mem.toBytes(@as(usize, offset + argv_pre_value_offset)), buffer[argv_pre_array_offset .. argv_pre_array_offset + @sizeOf(*u8)]);

    try std.testing.expectEqualSlices(u8, "Hello"[0..6], buffer[argv_pre_value_offset .. argv_pre_value_offset + 6]);
    try std.testing.expectEqualSlices(u8, "World!\n"[0..8], buffer[argv_pre_value_offset + 6 .. argv_pre_value_offset + 6 + 8]);
}

pub fn main() !void {
    var args = (try Args.parse()) orelse return;
    defer args.deinit();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const payload = Payload{
        .exec = args.exec,
        .argc_pre = args.argv_pre.len,
        .argv_pre = args.argv_pre.ptr,
    };
    const payload_size = payloadSize(payload);

    const shim_template = args.shim_template;

    var buffer = try allocator.allocBytes(
        @alignOf(*u8),
        shim_template.len + payload_size,
        @alignOf(*u8),
        @returnAddress(),
    );
    defer allocator.free(buffer);

    // Copy the shim template into the output buffer
    std.mem.copy(u8, buffer, shim_template);

    // Parse the ELF header from the output buffer
    var buffer_stream = std.io.fixedBufferStream(buffer);
    const elf_header = try std.elf.Header.read(&buffer_stream);

    // Parse the payload segment's Phdr.
    // TODO[AH] Support for 32-bit.
    // TODO[AH] Support for endiannes.
    var payload_phdr: std.elf.Elf64_Phdr = undefined;
    const payload_phdr_offset = elf_header.phoff + @sizeOf(@TypeOf(payload_phdr)) * (elf_header.phnum - 1);
    try buffer_stream.seekableStream().seekTo(payload_phdr_offset);
    try buffer_stream.reader().readNoEof(std.mem.asBytes(&payload_phdr));

    // Update the payload file and memory size in the output buffer.
    payload_phdr.p_filesz = payload_size;
    payload_phdr.p_memsz = payload_size;
    try buffer_stream.seekableStream().seekTo(payload_phdr_offset);
    try buffer_stream.writer().writeAll(std.mem.asBytes(&payload_phdr));

    // Encode the payload into the output buffer.
    try encodePayload(buffer[shim_template.len..], payload_phdr.p_vaddr, payload);

    // Write the shim.
    var out_file = try std.fs.cwd().createFile(args.out_path, .{});
    defer out_file.close();
    try out_file.writeAll(buffer);

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
