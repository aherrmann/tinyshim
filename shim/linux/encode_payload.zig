const builtin = @import("builtin");
const std = @import("std");
const Payload = @import("payload").Payload;

const native_endian = builtin.cpu.arch.endian();
const foreign_endian = switch (native_endian) {
    .Big => .Little,
    .Little => .Big,
};

pub const Bitwidth = enum {
    @"32",
    @"64",
};

pub fn SizeType(comptime bitwidth: Bitwidth) type {
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

pub fn payloadSize(bitwidth: Bitwidth, payload: Payload) usize {
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

fn streamWriteInt(stream: anytype, comptime T: type, value: T, endian: std.builtin.Endian) !void {
    try stream.writer().writeInt(T, value, endian);
}

fn streamWriteIntAt(stream: anytype, comptime T: type, pos: u64, value: T, endian: std.builtin.Endian) !void {
    const offset = try stream.seekableStream().getPos();
    try stream.seekableStream().seekTo(pos);
    try stream.writer().writeInt(T, value, endian);
    try stream.seekableStream().seekTo(offset);
}

fn streamWriteZ(stream: anytype, source: [*:0]const u8) !u64 {
    const offset = try stream.seekableStream().getPos();
    try stream.writer().writeAll(std.mem.sliceTo(source, 0));
    try stream.writer().writeByte(0);
    return offset;
}

pub fn encodePayload(comptime bitwidth: Bitwidth, endian: std.builtin.Endian, stream: anytype, offset: usize, payload: Payload) !void {
    const size_type = SizeType(bitwidth);
    const pointer_size = pointerSize(bitwidth);

    const stream_offset = try stream.seekableStream().getPos();

    const payload_exec_offset = try streamAdvance(stream, pointer_size);
    try streamWriteInt(stream, size_type, @intCast(size_type, payload.argc_pre), endian);
    const payload_argv_pre_offset = try streamAdvance(stream, pointer_size);

    var argv_pre_offset = try streamAdvance(stream, payload.argc_pre * pointer_size);
    try streamWriteIntAt(
        stream,
        size_type,
        payload_argv_pre_offset,
        @intCast(size_type, argv_pre_offset - stream_offset + offset),
        endian,
    );

    const exec_offset = try streamWriteZ(stream, payload.exec);
    try streamWriteIntAt(
        stream,
        size_type,
        payload_exec_offset,
        @intCast(size_type, exec_offset - stream_offset + offset),
        endian,
    );

    for (payload.argv_pre[0..payload.argc_pre]) |arg, i| {
        const arg_offset = try streamWriteZ(stream, arg);
        try streamWriteIntAt(
            stream,
            size_type,
            argv_pre_offset + i * pointer_size,
            @intCast(size_type, arg_offset - stream_offset + offset),
            endian,
        );
    }
}

fn testEncodePayloadEmpty(comptime bitwidth: Bitwidth, endian: std.builtin.Endian) !void {
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
    try encodePayload(bitwidth, endian, &stream, offset, payload);

    const payload_size = 3 * pointer_size;
    const payload_exec_offset = 0;
    try std.testing.expectEqualSlices(
        u8,
        &std.mem.toBytes(std.mem.toNative(
            size_type,
            @intCast(size_type, offset + payload_size),
            endian,
        )),
        buffer[payload_exec_offset .. payload_exec_offset + pointer_size],
    );

    const payload_argc_pre_offset = pointer_size;
    try std.testing.expectEqualSlices(
        u8,
        &std.mem.toBytes(std.mem.toNative(
            size_type,
            @as(size_type, 0),
            endian,
        )),
        buffer[payload_argc_pre_offset .. payload_argc_pre_offset + pointer_size],
    );

    const payload_argv_pre_offset = 2 * pointer_size;
    try std.testing.expectEqualSlices(
        u8,
        &std.mem.toBytes(std.mem.toNative(
            size_type,
            @intCast(size_type, offset + payload_size),
            endian,
        )),
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
    try testEncodePayloadEmpty(.@"32", native_endian);
}

test "encodePayload on empty payload at 64 bit" {
    try testEncodePayloadEmpty(.@"64", native_endian);
}

test "encodePayload on empty payload at 64 bit with foreign endian" {
    try testEncodePayloadEmpty(.@"64", foreign_endian);
}

fn testEncodePayloadNonEmpty(comptime bitwidth: Bitwidth, endian: std.builtin.Endian) !void {
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
    try encodePayload(bitwidth, endian, &stream, offset, payload);

    const payload_size = 3 * pointer_size;
    const payload_exec_offset = 0;
    const exec_offset = payload_size + 2 * pointer_size;
    try std.testing.expectEqualSlices(
        u8,
        &std.mem.toBytes(std.mem.toNative(
            size_type,
            @intCast(size_type, offset + exec_offset),
            endian,
        )),
        buffer[payload_exec_offset .. payload_exec_offset + pointer_size],
    );

    const payload_argc_pre_offset = pointer_size;
    try std.testing.expectEqualSlices(
        u8,
        &std.mem.toBytes(std.mem.toNative(
            size_type,
            @as(size_type, 2),
            endian,
        )),
        buffer[payload_argc_pre_offset .. payload_argc_pre_offset + pointer_size],
    );

    const payload_argv_pre_offset = 2 * pointer_size;
    const argv_pre_offset = payload_size;
    try std.testing.expectEqualSlices(
        u8,
        &std.mem.toBytes(std.mem.toNative(
            size_type,
            @intCast(size_type, offset + argv_pre_offset),
            endian,
        )),
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
        &std.mem.toBytes(std.mem.toNative(
            size_type,
            @intCast(size_type, offset + argv_pre_items_offset),
            endian,
        )),
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
    try testEncodePayloadNonEmpty(.@"32", native_endian);
}

test "encodePayload on non-empty payload at 64 bit" {
    try testEncodePayloadNonEmpty(.@"64", native_endian);
}

test "encodePayload on non-empty payload at 64 bit with foreign endian" {
    try testEncodePayloadNonEmpty(.@"64", foreign_endian);
}
