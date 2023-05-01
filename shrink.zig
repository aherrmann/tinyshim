const clap = @import("clap");
const std = @import("std");

const debug = std.debug;
const elf = std.elf;
const fs = std.fs;
const io = std.io;
const mem = std.mem;

const Args = struct {
    const exe_name = "shrink";
    const params = clap.parseParamsComptime(
        \\-h, --help   Display this help and exit.
        \\<FILE>       The ELF file to shrink.
        \\<PATH>       Where to store the shrunk ELF file.
        \\<STRING>     Delete sections after this.
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
        if (res.positionals.len < 3) {
            try io.getStdErr().writeAll("Missing positional argument\n\n");
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

fn readShstrtab(allocator: std.mem.Allocator, elf_header: elf.Header, parse_source: anytype) ![]u8 {
    if (elf_header.shstrndx == elf.SHN_UNDEF) {
        return error.ShstrtabUndefined;
    }

    var sh_iter = elf_header.section_header_iterator(parse_source);
    var shstrtab_shdr: ?elf.Elf64_Shdr = null;

    var index: usize = 0;
    while (try sh_iter.next()) |shdr| {
        if (index == elf_header.shstrndx) {
            shstrtab_shdr = shdr;
            break;
        }
        index += 1;
    }

    if (shstrtab_shdr) |shdr| {
        var shstrtab = try allocator.alloc(u8, shdr.sh_size);
        try parse_source.seekableStream().seekTo(shdr.sh_offset);
        if (try parse_source.reader().readAll(shstrtab) != shstrtab.len) {
            return error.IncompleteShstrtab;
        }
        return shstrtab;
    } else {
        return error.SectionHeaderNotFound;
    }
}

fn createTestElf(allocator: std.mem.Allocator, nobits_section: bool) ![]u8 {
    var buf: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const test_section_data: usize = if (nobits_section) 0 else 128;

    // Construct a minimal ELF binary with a valid shstrtab.
    const ehdr = elf.Elf64_Ehdr{
        .e_ident = .{
            0x7f, 'E', 'L', 'F', // Magic number
            elf.ELFCLASS64, // Class: 64-bit
            elf.ELFDATA2LSB, // Data: Little-endian
            1, // Version
            0, // OS ABI
            0, // ABI Version
            0, 0, 0, 0, 0, 0, 0, // Padding
        },
        .e_type = .EXEC,
        .e_machine = .X86_64,
        .e_version = 0,
        .e_entry = 0,
        .e_phoff = 0,
        .e_shoff = 128 + test_section_data,
        .e_flags = 0,
        .e_ehsize = @sizeOf(elf.Elf64_Ehdr),
        .e_phentsize = @sizeOf(elf.Elf64_Phdr),
        .e_phnum = 0,
        .e_shentsize = @sizeOf(elf.Elf64_Shdr),
        .e_shnum = 2,
        .e_shstrndx = 1,
    };

    const shstrtab_contents = ".test_section\x00.shstrtab\x00";

    const test_section = elf.Elf64_Shdr{
        .sh_name = 0,
        .sh_type = if (nobits_section) elf.SHT_NOBITS else elf.SHT_PROGBITS,
        .sh_size = 128,
        .sh_offset = 64,
        .sh_flags = 0,
        .sh_addr = 0,
        .sh_link = elf.SHN_UNDEF,
        .sh_info = 0,
        .sh_addralign = 1,
        .sh_entsize = 0,
    };

    const shstrtab_section = elf.Elf64_Shdr{
        .sh_name = 14,
        .sh_type = elf.SHT_STRTAB,
        .sh_size = shstrtab_contents.len,
        .sh_offset = 64 + test_section_data,
        .sh_flags = 0,
        .sh_addr = 0,
        .sh_link = elf.SHN_UNDEF,
        .sh_info = 0,
        .sh_addralign = 1,
        .sh_entsize = 0,
    };

    // EHDR
    try stream.writer().writeAll(mem.asBytes(&ehdr));
    try stream.seekableStream().seekTo(64);
    // test_section content
    if (!nobits_section) {
        var i: usize = 0;
        while (i < test_section_data) : (i += 1) {
            try stream.writer().writeByte(@truncate(u8, i));
        }
    }
    // shstrtab content
    try stream.writer().writeAll(shstrtab_contents);
    try stream.seekableStream().seekTo(64 + test_section_data + 64);
    // section header table
    try stream.writer().writeAll(mem.asBytes(&test_section));
    try stream.seekableStream().seekTo(64 + test_section_data + 64 + @sizeOf(elf.Elf64_Shdr));
    try stream.writer().writeAll(mem.asBytes(&shstrtab_section));

    const output_buf = try allocator.alloc(u8, buf.len);
    mem.copy(u8, output_buf, &buf);

    return output_buf;
}

test "readShstrtab: success" {
    var allocator = std.testing.allocator;

    const buf = try createTestElf(allocator, false);
    defer allocator.free(buf);

    var read_stream = std.io.fixedBufferStream(buf);
    const input_elf = try elf.Header.read(&read_stream);

    const result = try readShstrtab(allocator, input_elf, &read_stream);
    defer allocator.free(result);

    try std.testing.expectEqualSlices(u8, ".test_section\x00.shstrtab\x00", result);
}

test "readShstrtab: SHN_UNDEF" {
    var buf: [256]u8 = undefined;
    var read_stream = std.io.fixedBufferStream(&buf);
    var allocator = std.testing.allocator;

    // Construct an ELF header with an undefined shstrtab.
    var input_elf = elf.Header{
        .is_64 = true,
        .shstrndx = elf.SHN_UNDEF,
        .shnum = 1,
        .shentsize = @sizeOf(elf.Elf64_Shdr),
        .shoff = 64,
        .endian = .Little,
        .machine = .X86_64,
        .entry = 0,
        .phoff = 0,
        .phentsize = @sizeOf(elf.Elf64_Phdr),
        .phnum = 0,
    };

    const result = readShstrtab(allocator, input_elf, &read_stream);
    try std.testing.expectError(error.ShstrtabUndefined, result);
}

test "readShstrtab: SectionHeaderNotFound" {
    var buf: [256]u8 = undefined;
    var read_stream = std.io.fixedBufferStream(&buf);
    var allocator = std.testing.allocator;

    // Construct an ELF header with a missing shstrtab.
    var input_elf = elf.Header{
        .is_64 = true,
        .shstrndx = 1,
        .shnum = 1,
        .shentsize = @sizeOf(elf.Elf64_Shdr),
        .shoff = 64,
        .endian = .Little,
        .machine = .X86_64,
        .entry = 0,
        .phoff = 0,
        .phentsize = @sizeOf(elf.Elf64_Phdr),
        .phnum = 0,
    };

    const result = readShstrtab(allocator, input_elf, &read_stream);
    try std.testing.expectError(error.SectionHeaderNotFound, result);
}

fn findSectionIndexByName(
    elf_header: elf.Header,
    parse_source: anytype,
    shstrtab: []const u8,
    section_name: []const u8,
) !u16 {
    var sh_iter = elf_header.section_header_iterator(parse_source);
    var section_index: u16 = 0;
    while (try sh_iter.next()) |shdr| {
        const current_section_name = std.mem.sliceTo(shstrtab[shdr.sh_name..], 0);
        if (std.mem.eql(u8, current_section_name, section_name)) {
            return section_index;
        }
        section_index += 1;
    }
    return error.SectionNotFound;
}

test "findSectionIndexByName success" {
    const allocator = std.testing.allocator;

    // Prepare the ELF header and section headers in memory
    var buffer = try createTestElf(allocator, false);
    defer allocator.free(buffer);

    var parse_source = io.fixedBufferStream(buffer);

    // Read the ELF header
    const elf_header = try elf.Header.read(&parse_source);

    // Read the shstrtab
    const shstrtab = try readShstrtab(allocator, elf_header, &parse_source);
    defer allocator.free(shstrtab);

    const target_section_name = ".test_section";
    const target_section_index = try findSectionIndexByName(elf_header, parse_source, shstrtab, target_section_name);
    try std.testing.expectEqual(@as(u16, 0), target_section_index);
}

test "findSectionIndexByName failure" {
    const allocator = std.testing.allocator;

    // Prepare the ELF header and section headers in memory
    var buffer = try createTestElf(allocator, false);
    defer allocator.free(buffer);

    var parse_source = io.fixedBufferStream(buffer);

    // Read the ELF header
    const elf_header = try elf.Header.read(&parse_source);

    // Read the shstrtab
    const shstrtab = try readShstrtab(allocator, elf_header, &parse_source);
    defer allocator.free(shstrtab);

    const nonexistent_section_name = ".nonexistent";
    const result = findSectionIndexByName(elf_header, parse_source, shstrtab, nonexistent_section_name);
    try std.testing.expectError(error.SectionNotFound, result);
}

fn getSectionEndOffset(
    elf_header: elf.Header,
    parse_source: anytype,
    section_index: u16,
) !u64 {
    var sh_iter = elf_header.section_header_iterator(parse_source);

    var current_index: u16 = 0;
    while (try sh_iter.next()) |shdr| {
        if (current_index == section_index) {
            if (shdr.sh_type == elf.SHT_NOBITS) {
                return shdr.sh_offset;
            } else {
                return shdr.sh_offset + shdr.sh_size;
            }
        }
        current_index += 1;
    }

    return error.SectionIndexNotFound;
}

test "getSectionEndOffset success" {
    var allocator = std.testing.allocator;
    const elf_data = try createTestElf(allocator, false);
    defer allocator.free(elf_data);
    var parse_source = io.fixedBufferStream(elf_data);
    const input_elf = try elf.Header.read(&parse_source);

    const end_offset = try getSectionEndOffset(input_elf, &parse_source, input_elf.shstrndx);
    try std.testing.expectEqual(@as(u64, 192 + ".test_section\x00.shstrtab\x00".len), end_offset);
}

test "getSectionEndOffset non-existent section index" {
    var allocator = std.testing.allocator;
    const elf_data = try createTestElf(allocator, false);
    defer allocator.free(elf_data);
    var parse_source = io.fixedBufferStream(elf_data);
    const input_elf = try elf.Header.read(&parse_source);

    const result = getSectionEndOffset(input_elf, &parse_source, 2);
    try std.testing.expectError(error.SectionIndexNotFound, result);
}

test "getSectionEndOffset success with NOBITS section" {
    var allocator = std.testing.allocator;
    const elf_data = try createTestElf(allocator, true);
    defer allocator.free(elf_data);
    var parse_source = io.fixedBufferStream(elf_data);
    const input_elf = try elf.Header.read(&parse_source);

    const end_offset = try getSectionEndOffset(input_elf, &parse_source, 0);
    try std.testing.expectEqual(@as(u64, 64), end_offset);
}

fn removeSectionHeadersAndShstrtab(buffer: anytype) !void {
    const input_elf = try elf.Header.read(buffer);

    // Read the raw bytes of the ELF header
    var elf_header_bytes: [@sizeOf(elf.Elf64_Ehdr)]u8 align(8) = undefined;
    try buffer.seekableStream().seekTo(0);
    try buffer.reader().readNoEof(&elf_header_bytes);

    // Update the ELF header to remove the section table
    if (input_elf.is_64) {
        const header64 = @ptrCast(*elf.Elf64_Ehdr, &elf_header_bytes);
        header64.e_shoff = 0;
        header64.e_shentsize = 0;
        header64.e_shnum = 0;
        header64.e_shstrndx = 0;
    } else {
        const header32 = @ptrCast(*elf.Elf32_Ehdr, &elf_header_bytes);
        header32.e_shoff = 0;
        header32.e_shentsize = 0;
        header32.e_shnum = 0;
        header32.e_shstrndx = 0;
    }

    // Write the updated ELF header
    try buffer.seekableStream().seekTo(0);
    try buffer.writer().writeAll(&elf_header_bytes);
}

test "removeSectionHeadersAndShstrtab" {
    const allocator = std.testing.allocator;

    // Create the test ELF file
    var test_elf = try createTestElf(allocator, false);
    defer allocator.free(test_elf);

    // Create a fixedBufferStream for the test ELF file
    var buf_stream = io.fixedBufferStream(test_elf);

    // Remove the section headers and shstrtab
    try removeSectionHeadersAndShstrtab(&buf_stream);

    // Read the modified ELF header
    const modified_elf = try elf.Header.read(&buf_stream);

    // Check that the section header table is removed
    try std.testing.expectEqual(@as(u64, 0), modified_elf.shoff);
    try std.testing.expectEqual(@as(u16, 0), modified_elf.shentsize);
    try std.testing.expectEqual(@as(u16, 0), modified_elf.shnum);
    try std.testing.expectEqual(@as(u16, 0), modified_elf.shstrndx);
}

fn dropSectionsPastTarget(
    allocator: mem.Allocator,
    parse_source: anytype,
    target_section_name: []const u8,
) ![]u8 {
    const input_elf_header = try elf.Header.read(parse_source);

    const shstrtab = try readShstrtab(allocator, input_elf_header, parse_source);
    defer allocator.free(shstrtab);

    const target_section_index = try findSectionIndexByName(input_elf_header, parse_source, shstrtab, target_section_name);

    const section_end_offset = try getSectionEndOffset(input_elf_header, parse_source, target_section_index);

    var new_elf_buffer = try allocator.alloc(u8, section_end_offset);
    var new_elf_stream = io.fixedBufferStream(new_elf_buffer);

    try parse_source.seekableStream().seekTo(0);
    try parse_source.reader().readNoEof(new_elf_buffer);

    try removeSectionHeadersAndShstrtab(&new_elf_stream);

    return new_elf_buffer;
}

test "dropSectionsPastTarget" {
    const allocator = std.testing.allocator;

    // Create an ELF binary with a test section
    const input_elf_data = try createTestElf(allocator, false);
    defer allocator.free(input_elf_data);
    var input_stream = std.io.fixedBufferStream(input_elf_data);

    // Call the dropSectionsPastTarget function
    const target_section_name = ".test_section";
    var modified_elf_data = try dropSectionsPastTarget(allocator, &input_stream, target_section_name);
    defer allocator.free(modified_elf_data);
    var modified_stream = std.io.fixedBufferStream(modified_elf_data);

    // Read the modified ELF header
    const modified_elf_header = try elf.Header.read(&modified_stream);

    // Check that the section headers and shstrtab have been removed
    try std.testing.expectEqual(@as(u16, 0), modified_elf_header.shnum);
    try std.testing.expectEqual(@as(u16, 0), modified_elf_header.shentsize);
    try std.testing.expectEqual(@as(u16, elf.SHN_UNDEF), modified_elf_header.shstrndx);
    try std.testing.expectEqual(@as(u64, 0), modified_elf_header.shoff);

    // Check that the ELF file was truncated at the end of the target section
    try std.testing.expectEqual(@as(usize, 192), modified_elf_data.len);
}

fn shrink(
    allocator: mem.Allocator,
    input_path: []const u8,
    output_path: []const u8,
    target_section_name: []const u8,
) !void {
    const input_file = try fs.cwd().openFile(input_path, .{});
    defer input_file.close();

    const modified_data = try dropSectionsPastTarget(allocator, input_file, target_section_name);
    defer allocator.free(modified_data);

    const output_file = try fs.cwd().createFile(output_path, .{});
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
