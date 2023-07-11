const builtin = @import("builtin");
const std = @import("std");
const Payload = @import("payload").Payload;
const encode_payload = @import("encode_payload");
const Bitwidth = encode_payload.Bitwidth;

const native_endian = builtin.cpu.arch.endian();

fn appendPayload(
    comptime bitwidth: Bitwidth,
    stream: *std.io.StreamSource,
    payload: Payload,
    header: std.elf.Header,
) !void {
    std.debug.assert(header.is_64 == (bitwidth == .@"64"));
    const endian = header.endian;
    const need_bswap = endian != native_endian;

    const payload_pos = try stream.seekableStream().getPos();
    const payload_size = encode_payload.payloadSize(bitwidth, payload);

    // Parse the payload segment's Phdr.
    const Phdr = switch (bitwidth) {
        .@"32" => std.elf.Elf32_Phdr,
        .@"64" => std.elf.Elf64_Phdr,
    };
    var payload_phdr: Phdr = undefined;
    const payload_phdr_offset = header.phoff + @sizeOf(Phdr) * (header.phnum - 1);
    try stream.seekableStream().seekTo(payload_phdr_offset);
    try stream.reader().readNoEof(std.mem.asBytes(&payload_phdr));
    if (need_bswap) {
        std.mem.byteSwapAllFields(Phdr, &payload_phdr);
    }
    const payload_vaddr = payload_phdr.p_vaddr;

    // Update the payload file and memory size in the output buffer.
    const size_type = encode_payload.SizeType(bitwidth);
    payload_phdr.p_filesz = @intCast(size_type, payload_size);
    payload_phdr.p_memsz = @intCast(size_type, payload_size);
    try stream.seekableStream().seekTo(payload_phdr_offset);
    if (need_bswap) {
        std.mem.byteSwapAllFields(Phdr, &payload_phdr);
    }
    try stream.writer().writeAll(std.mem.asBytes(&payload_phdr));

    // Encode the payload into the output buffer.
    try stream.seekableStream().seekTo(payload_pos);
    try encode_payload.encodePayload(bitwidth, endian, stream, payload_vaddr, payload);
}

pub fn generateShim(
    allocator: std.mem.Allocator,
    payload: Payload,
    template: []const u8,
) ![]u8 {
    var template_stream = std.io.fixedBufferStream(template);
    const template_header = try std.elf.Header.read(&template_stream);

    const bitwidth: Bitwidth = if (template_header.is_64) .@"64" else .@"32";
    const payload_size = encode_payload.payloadSize(bitwidth, payload);
    var buffer = try allocator.alloc(u8, template.len + payload_size);
    errdefer allocator.free(buffer);
    var stream = std.io.StreamSource{ .buffer = std.io.fixedBufferStream(buffer) };

    try stream.writer().writeAll(template);

    try switch (bitwidth) {
        inline else => |bw| appendPayload(
            bw,
            &stream,
            payload,
            template_header,
        ),
    };

    return buffer;
}
