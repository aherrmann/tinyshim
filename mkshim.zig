const builtin = @import("builtin");
const clap = @import("clap");
const std = @import("std");
const shim_templates = @import("shim_templates");
const Payload = @import("payload.zig").Payload;

const native_target = @tagName(builtin.target.cpu.arch) ++ "-" ++ @tagName(builtin.target.os.tag);

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

const Bitwidth = enum {
    @"32",
    @"64",
};

fn SizeType(comptime bitwidth: Bitwidth) type {
    return switch (bitwidth) {
        .@"32" => u32,
        .@"64" => u64,
    };
}

fn pointerSize(bitwidth: Bitwidth) usize {
    return switch (bitwidth) {
        .@"32" => 4,
        .@"64" => 8,
    };
}

fn pointerAlignment(bitwidth: Bitwidth) usize {
    return switch (bitwidth) {
        .@"32" => 4,
        .@"64" => 8,
    };
}

fn payloadSize(bitwidth: Bitwidth, payload: Payload) usize {
    var result: usize = 0;

    const pointer_size = pointerSize(bitwidth);
    const pointer_align = pointerAlignment(bitwidth);

    // Payload struct
    result += pointer_size; // exec
    result += pointer_size; // argc_pre
    result += pointer_size; // argv_pre

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
        .exec = "", // 4/8 + 1
        .argc_pre = 0, // 4/8
        .argv_pre = &[_][*:0]const u8{}, // 4/8 + 0
    };

    try std.testing.expectEqual(4 + 4 + 4 + std.mem.alignForward(1, 4), payloadSize(.@"32", payload));
    try std.testing.expectEqual(8 + 8 + 8 + std.mem.alignForward(1, 8), payloadSize(.@"64", payload));
}

test "payloadSize on non-empty payload" {
    const payload = Payload{
        .exec = "/bin/echo", // 4/8 + 10
        .argc_pre = 2, // 4/8
        .argv_pre = &[_][*:0]const u8{ "Hello", "World!\n" }, // 4/8 + 2*4/8 + 6 + 8
    };

    try std.testing.expectEqual(4 + 4 + 4 + 2 * 4 + std.mem.alignForward(10 + 6 + 8, 4), payloadSize(.@"32", payload));
    try std.testing.expectEqual(8 + 8 + 8 + 2 * 8 + std.mem.alignForward(10 + 6 + 8, 8), payloadSize(.@"64", payload));
}

fn streamAdvance(stream: anytype, size: usize) !u64 {
    const offset = try stream.seekableStream().getPos();
    try stream.seekableStream().seekBy(@intCast(i64, size));
    return offset;
}

fn streamWriteInt(stream: anytype, comptime T: type, value: T) !void {
    // TODO[AH] Support non-native endian.
    try stream.writer().writeIntNative(T, value);
}

fn streamWriteIntAt(stream: anytype, comptime T: type, pos: u64, value: T) !void {
    const offset = try stream.seekableStream().getPos();
    try stream.seekableStream().seekTo(pos);
    // TODO[AH] Support non-native endian.
    try stream.writer().writeIntNative(T, value);
    try stream.seekableStream().seekTo(offset);
}

fn streamWriteZ(stream: anytype, source: [*:0]const u8) !u64 {
    const offset = try stream.seekableStream().getPos();
    try stream.writer().writeAll(std.mem.sliceTo(source, 0));
    try stream.writer().writeByte(0);
    return offset;
}

fn encodePayload(comptime bitwidth: Bitwidth, stream: anytype, offset: usize, payload: Payload) !void {
    const size_type = SizeType(bitwidth);
    const pointer_size = pointerSize(bitwidth);

    const stream_offset = try stream.seekableStream().getPos();

    const payload_exec_offset = try streamAdvance(stream, pointer_size);
    try streamWriteInt(stream, size_type, @intCast(size_type, payload.argc_pre));
    const payload_argv_pre_offset = try streamAdvance(stream, pointer_size);

    var argv_pre_offset = try streamAdvance(stream, payload.argc_pre * pointer_size);
    try streamWriteIntAt(
        stream,
        size_type,
        payload_argv_pre_offset,
        @intCast(size_type, argv_pre_offset - stream_offset + offset),
    );

    const exec_offset = try streamWriteZ(stream, payload.exec);
    try streamWriteIntAt(
        stream,
        size_type,
        payload_exec_offset,
        @intCast(size_type, exec_offset - stream_offset + offset),
    );

    for (payload.argv_pre[0..payload.argc_pre]) |arg, i| {
        const arg_offset = try streamWriteZ(stream, arg);
        try streamWriteIntAt(
            stream,
            size_type,
            argv_pre_offset + i * pointer_size,
            @intCast(size_type, arg_offset - stream_offset + offset),
        );
    }
}

fn testEncodePayloadEmpty(comptime bitwidth: Bitwidth) !void {
    const size_type = SizeType(bitwidth);
    const pointer_size = pointerSize(bitwidth);
    const pointer_align = pointerAlignment(bitwidth);

    const allocator = std.testing.allocator;

    const payload = Payload{
        .exec = "",
        .argc_pre = 0,
        .argv_pre = &[_][*:0]const u8{},
    };

    var buffer = try allocator.alloc(u8, payloadSize(bitwidth, payload));
    defer allocator.free(buffer);

    var stream = std.io.fixedBufferStream(buffer);
    const offset: usize = 8 * pointer_align;
    try encodePayload(bitwidth, &stream, offset, payload);

    const payload_size = 3 * pointer_size;
    const payload_exec_offset = 0;
    try std.testing.expectEqualSlices(
        u8,
        &std.mem.toBytes(@intCast(size_type, offset + payload_size)),
        buffer[payload_exec_offset .. payload_exec_offset + pointer_size],
    );

    const payload_argc_pre_offset = pointer_size;
    try std.testing.expectEqualSlices(
        u8,
        &std.mem.toBytes(@as(size_type, 0)),
        buffer[payload_argc_pre_offset .. payload_argc_pre_offset + pointer_size],
    );

    const payload_argv_pre_offset = 2 * pointer_size;
    try std.testing.expectEqualSlices(
        u8,
        &std.mem.toBytes(@intCast(size_type, offset + payload_size)),
        buffer[payload_argv_pre_offset .. payload_argv_pre_offset + pointer_size],
    );

    const exec_offset = payload_size;
    try std.testing.expectEqualSlices(
        u8,
        ""[0..1],
        buffer[exec_offset .. exec_offset + 1],
    );
}

test "encodePayload on empty payload at 32 bit" {
    try testEncodePayloadEmpty(.@"32");
}

test "encodePayload on empty payload at 64 bit" {
    try testEncodePayloadEmpty(.@"64");
}

fn testEncodePayloadNonEmpty(comptime bitwidth: Bitwidth) !void {
    const size_type = SizeType(bitwidth);
    const pointer_size = pointerSize(bitwidth);
    const pointer_align = pointerAlignment(bitwidth);

    const allocator = std.testing.allocator;

    const payload = Payload{
        .exec = "/bin/echo",
        .argc_pre = 2,
        .argv_pre = &[_][*:0]const u8{ "Hello", "World!\n" },
    };

    var buffer = try allocator.alloc(u8, payloadSize(bitwidth, payload));
    defer allocator.free(buffer);

    var stream = std.io.fixedBufferStream(buffer);
    const offset: usize = 8 * pointer_align;
    try encodePayload(bitwidth, &stream, offset, payload);

    const payload_size = 3 * pointer_size;
    const payload_exec_offset = 0;
    const exec_offset = payload_size + 2 * pointer_size;
    try std.testing.expectEqualSlices(
        u8,
        &std.mem.toBytes(@intCast(size_type, offset + exec_offset)),
        buffer[payload_exec_offset .. payload_exec_offset + pointer_size],
    );

    const payload_argc_pre_offset = pointer_size;
    try std.testing.expectEqualSlices(
        u8,
        &std.mem.toBytes(@as(size_type, 2)),
        buffer[payload_argc_pre_offset .. payload_argc_pre_offset + pointer_size],
    );

    const payload_argv_pre_offset = 2 * pointer_size;
    const argv_pre_offset = payload_size;
    try std.testing.expectEqualSlices(
        u8,
        &std.mem.toBytes(@intCast(size_type, offset + argv_pre_offset)),
        buffer[payload_argv_pre_offset .. payload_argv_pre_offset + pointer_size],
    );

    try std.testing.expectEqualSlices(
        u8,
        "/bin/echo"[0..10],
        buffer[exec_offset .. exec_offset + 10],
    );

    const argv_pre_items_offset = exec_offset + 10;
    try std.testing.expectEqualSlices(
        u8,
        &std.mem.toBytes(@intCast(size_type, offset + argv_pre_items_offset)),
        buffer[argv_pre_offset .. argv_pre_offset + pointer_size],
    );

    try std.testing.expectEqualSlices(
        u8,
        "Hello"[0..6],
        buffer[argv_pre_items_offset .. argv_pre_items_offset + 6],
    );
    try std.testing.expectEqualSlices(
        u8,
        "World!\n"[0..8],
        buffer[argv_pre_items_offset + 6 .. argv_pre_items_offset + 6 + 8],
    );
}

test "encodePayload on non-empty payload at 32 bit" {
    try testEncodePayloadNonEmpty(.@"32");
}

test "encodePayload on non-empty payload at 64 bit" {
    try testEncodePayloadNonEmpty(.@"64");
}

fn generateShim(
    allocator: std.mem.Allocator,
    comptime bitwidth: Bitwidth,
    payload: Payload,
    template: []const u8,
    header: std.elf.Header,
) ![]u8 {
    const payload_size = payloadSize(bitwidth, payload);

    var buffer = try allocator.allocBytes(
        @alignOf(*u8),
        template.len + payload_size,
        @alignOf(*u8),
        @returnAddress(),
    );
    var stream = std.io.fixedBufferStream(buffer);

    try stream.writer().writeAll(template);

    // Parse the payload segment's Phdr.
    // TODO[AH] Support for endiannes.
    const Phdr = switch (bitwidth) {
        .@"32" => std.elf.Elf32_Phdr,
        .@"64" => std.elf.Elf64_Phdr,
    };
    var payload_phdr: Phdr = undefined;
    const payload_phdr_offset = header.phoff + @sizeOf(Phdr) * (header.phnum - 1);
    try stream.seekableStream().seekTo(payload_phdr_offset);
    try stream.reader().readNoEof(std.mem.asBytes(&payload_phdr));

    // Update the payload file and memory size in the output buffer.
    const size_type = SizeType(bitwidth);
    payload_phdr.p_filesz = @intCast(size_type, payload_size);
    payload_phdr.p_memsz = @intCast(size_type, payload_size);
    try stream.seekableStream().seekTo(payload_phdr_offset);
    try stream.writer().writeAll(std.mem.asBytes(&payload_phdr));

    // Encode the payload into the output buffer.
    try stream.seekableStream().seekTo(template.len);
    try encodePayload(bitwidth, &stream, payload_phdr.p_vaddr, payload);

    return buffer;
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

    // Load the shim template.
    const template = args.shim_template;
    var template_stream = std.io.fixedBufferStream(template);
    const template_header = try std.elf.Header.read(&template_stream);

    const shim = try if (template_header.is_64)
        generateShim(allocator, .@"64", payload, template, template_header)
    else
        generateShim(allocator, .@"32", payload, template, template_header);
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
