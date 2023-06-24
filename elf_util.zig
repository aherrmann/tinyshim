const std = @import("std");

/// Reads the section header string table (shstrtab) from the given ELF file.
/// The `elf_header` and `parse_source` should correspond to a valid ELF file.
/// Allocates memory for the shstrtab using the provided `allocator`.
/// Returns the shstrtab as a slice of bytes on success or an error on failure.
///
/// Errors:
///     - `ShstrtabUndefined`: The shstrtab is not defined in the ELF header.
///     - `SectionHeaderNotFound`: The section header for the shstrtab is not found.
///     - `IncompleteShstrtab`: The shstrtab is not completely read from the ELF file.
///
/// Note: The caller is responsible for deallocating the memory of the returned shstrtab.
pub fn readShstrtab(allocator: std.mem.Allocator, elf_header: std.elf.Header, parse_source: anytype) ![]u8 {
    if (elf_header.shstrndx == std.elf.SHN_UNDEF) {
        return error.ShstrtabUndefined;
    }

    var sh_iter = elf_header.section_header_iterator(parse_source);
    var shstrtab_shdr: ?std.elf.Elf64_Shdr = null;

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

/// Creates a test ELF file with a single section that is either a NOBITS or a PROGBITS section
/// depending on the `nobits_section` parameter and a shstrtab.
///
/// Arguments:
///   allocator: An instance of `std.mem.Allocator` to allocate memory for the resulting ELF data.
///   nobits_section: A boolean to indicate whether the test section should be a NOBITS section.
///                   If `true`, the test section will be a NOBITS section with a non-zero size
///                   but no actual data in the file. If `false`, the test section will be a
///                   PROGBITS section with actual data.
///
/// Returns:
///   A slice of bytes representing the generated ELF data. The caller is responsible for
///   freeing the memory allocated by the allocator.
fn createTestElf(allocator: std.mem.Allocator, nobits_section: bool) ![]u8 {
    var buf: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const test_section_data: usize = if (nobits_section) 0 else 128;

    // Construct a minimal ELF binary with a valid shstrtab.
    const ehdr = std.elf.Elf64_Ehdr{
        .e_ident = .{
            0x7f, 'E', 'L', 'F', // Magic number
            std.elf.ELFCLASS64, // Class: 64-bit
            std.elf.ELFDATA2LSB, // Data: Little-endian
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
        .e_ehsize = @sizeOf(std.elf.Elf64_Ehdr),
        .e_phentsize = @sizeOf(std.elf.Elf64_Phdr),
        .e_phnum = 0,
        .e_shentsize = @sizeOf(std.elf.Elf64_Shdr),
        .e_shnum = 2,
        .e_shstrndx = 1,
    };

    const shstrtab_contents = ".test_section\x00.shstrtab\x00";

    const test_section = std.elf.Elf64_Shdr{
        .sh_name = 0,
        .sh_type = if (nobits_section) std.elf.SHT_NOBITS else std.elf.SHT_PROGBITS,
        .sh_size = 128,
        .sh_offset = 64,
        .sh_flags = 0,
        .sh_addr = 0,
        .sh_link = std.elf.SHN_UNDEF,
        .sh_info = 0,
        .sh_addralign = 1,
        .sh_entsize = 0,
    };

    const shstrtab_section = std.elf.Elf64_Shdr{
        .sh_name = 14,
        .sh_type = std.elf.SHT_STRTAB,
        .sh_size = shstrtab_contents.len,
        .sh_offset = 64 + test_section_data,
        .sh_flags = 0,
        .sh_addr = 0,
        .sh_link = std.elf.SHN_UNDEF,
        .sh_info = 0,
        .sh_addralign = 1,
        .sh_entsize = 0,
    };

    // EHDR
    try stream.writer().writeAll(std.mem.asBytes(&ehdr));
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
    try stream.writer().writeAll(std.mem.asBytes(&test_section));
    try stream.seekableStream().seekTo(64 + test_section_data + 64 + @sizeOf(std.elf.Elf64_Shdr));
    try stream.writer().writeAll(std.mem.asBytes(&shstrtab_section));

    const output_buf = try allocator.alloc(u8, buf.len);
    std.mem.copy(u8, output_buf, &buf);

    return output_buf;
}

test "readShstrtab: success" {
    var allocator = std.testing.allocator;

    const buf = try createTestElf(allocator, false);
    defer allocator.free(buf);

    var read_stream = std.io.fixedBufferStream(buf);
    const input_elf = try std.elf.Header.read(&read_stream);

    const result = try readShstrtab(allocator, input_elf, &read_stream);
    defer allocator.free(result);

    try std.testing.expectEqualSlices(u8, ".test_section\x00.shstrtab\x00", result);
}

test "readShstrtab: SHN_UNDEF" {
    var buf: [256]u8 = undefined;
    var read_stream = std.io.fixedBufferStream(&buf);
    var allocator = std.testing.allocator;

    // Construct an ELF header with an undefined shstrtab.
    var input_elf = std.elf.Header{
        .is_64 = true,
        .shstrndx = std.elf.SHN_UNDEF,
        .shnum = 1,
        .shentsize = @sizeOf(std.elf.Elf64_Shdr),
        .shoff = 64,
        .endian = .Little,
        .machine = .X86_64,
        .entry = 0,
        .phoff = 0,
        .phentsize = @sizeOf(std.elf.Elf64_Phdr),
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
    var input_elf = std.elf.Header{
        .is_64 = true,
        .shstrndx = 1,
        .shnum = 1,
        .shentsize = @sizeOf(std.elf.Elf64_Shdr),
        .shoff = 64,
        .endian = .Little,
        .machine = .X86_64,
        .entry = 0,
        .phoff = 0,
        .phentsize = @sizeOf(std.elf.Elf64_Phdr),
        .phnum = 0,
    };

    const result = readShstrtab(allocator, input_elf, &read_stream);
    try std.testing.expectError(error.SectionHeaderNotFound, result);
}

/// Returns the index of an ELF section with the given name in the shstrtab,
/// `error.SectionNotFound` otherwise.
///
/// * `elf_header`: The ELF header of the file.
/// * `parse_source`: A seekable stream for the ELF file.
/// * `shstrtab`: A slice containing the contents of the shstrtab section.
/// * `section_name`: The name of the section to find.
pub fn findSectionIndexByName(
    elf_header: std.elf.Header,
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

    var parse_source = std.io.fixedBufferStream(buffer);

    // Read the ELF header
    const elf_header = try std.elf.Header.read(&parse_source);

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

    var parse_source = std.io.fixedBufferStream(buffer);

    // Read the ELF header
    const elf_header = try std.elf.Header.read(&parse_source);

    // Read the shstrtab
    const shstrtab = try readShstrtab(allocator, elf_header, &parse_source);
    defer allocator.free(shstrtab);

    const nonexistent_section_name = ".nonexistent";
    const result = findSectionIndexByName(elf_header, parse_source, shstrtab, nonexistent_section_name);
    try std.testing.expectError(error.SectionNotFound, result);
}

/// Returns the past the end offset of the specified section in an ELF file,
/// i.e. the offset immediately following the section's data (if any) in the file.
/// Returns `error.SectionIndexNotFound` if the given section index is not found.
///
/// * `elf_header`: The ELF header of the input file.
/// * `parse_source`: A seekable stream or fixed buffer stream of the input ELF file.
/// * `section_index`: The index of the section for which the end offset is required.
pub fn getSectionEndOffset(
    elf_header: std.elf.Header,
    parse_source: anytype,
    section_index: u16,
) !u64 {
    var sh_iter = elf_header.section_header_iterator(parse_source);

    var current_index: u16 = 0;
    while (try sh_iter.next()) |shdr| : (current_index += 1) {
        if (current_index == section_index) {
            if (shdr.sh_type == std.elf.SHT_NOBITS) {
                return shdr.sh_offset;
            } else {
                return shdr.sh_offset + shdr.sh_size;
            }
        }
    }

    return error.SectionIndexNotFound;
}

test "getSectionEndOffset success" {
    var allocator = std.testing.allocator;
    const elf_data = try createTestElf(allocator, false);
    defer allocator.free(elf_data);
    var parse_source = std.io.fixedBufferStream(elf_data);
    const input_elf = try std.elf.Header.read(&parse_source);

    const end_offset = try getSectionEndOffset(input_elf, &parse_source, input_elf.shstrndx);
    try std.testing.expectEqual(@as(u64, 192 + ".test_section\x00.shstrtab\x00".len), end_offset);
}

test "getSectionEndOffset non-existent section index" {
    var allocator = std.testing.allocator;
    const elf_data = try createTestElf(allocator, false);
    defer allocator.free(elf_data);
    var parse_source = std.io.fixedBufferStream(elf_data);
    const input_elf = try std.elf.Header.read(&parse_source);

    const result = getSectionEndOffset(input_elf, &parse_source, 2);
    try std.testing.expectError(error.SectionIndexNotFound, result);
}

test "getSectionEndOffset success with NOBITS section" {
    var allocator = std.testing.allocator;
    const elf_data = try createTestElf(allocator, true);
    defer allocator.free(elf_data);
    var parse_source = std.io.fixedBufferStream(elf_data);
    const input_elf = try std.elf.Header.read(&parse_source);

    const end_offset = try getSectionEndOffset(input_elf, &parse_source, 0);
    try std.testing.expectEqual(@as(u64, 64), end_offset);
}

/// Returns the start offset of the specified section in an ELF file.
/// Returns `error.SectionIndexNotFound` if the given section index is not found.
///
/// * `elf_header`: The ELF header of the input file.
/// * `parse_source`: A seekable stream or fixed buffer stream of the input ELF file.
/// * `section_index`: The index of the section for which the start offset is required.
fn getSectionStartOffset(
    elf_header: std.elf.Header,
    parse_source: anytype,
    section_index: u16,
) !usize {
    var sh_iter = elf_header.section_header_iterator(parse_source);

    var current_index: u16 = 0;
    while (try sh_iter.next()) |shdr| : (current_index += 1) {
        if (current_index == section_index) {
            return shdr.sh_offset;
        }
    }

    return error.SectionIndexNotFound;
}

test "getSectionStartOffset success" {
    var allocator = std.testing.allocator;
    const elf_data = try createTestElf(allocator, false);
    defer allocator.free(elf_data);
    var parse_source = std.io.fixedBufferStream(elf_data);
    const input_elf = try std.elf.Header.read(&parse_source);

    const start_offset = try getSectionStartOffset(input_elf, &parse_source, input_elf.shstrndx);
    try std.testing.expectEqual(@as(u64, 192), start_offset);
}

test "getSectionStartOffset non-existent section index" {
    var allocator = std.testing.allocator;
    const elf_data = try createTestElf(allocator, false);
    defer allocator.free(elf_data);
    var parse_source = std.io.fixedBufferStream(elf_data);
    const input_elf = try std.elf.Header.read(&parse_source);

    const result = getSectionStartOffset(input_elf, &parse_source, 2);
    try std.testing.expectError(error.SectionIndexNotFound, result);
}

test "getSectionStartOffset success with NOBITS section" {
    var allocator = std.testing.allocator;
    const elf_data = try createTestElf(allocator, true);
    defer allocator.free(elf_data);
    var parse_source = std.io.fixedBufferStream(elf_data);
    const input_elf = try std.elf.Header.read(&parse_source);

    const end_offset = try getSectionStartOffset(input_elf, &parse_source, 0);
    try std.testing.expectEqual(@as(u64, 64), end_offset);
}

/// This function modifies the ELF header in the buffer to remove references to the
/// section header table and the shstrtab, effectively deleting these sections.
/// The buffer must provide a .reader(), .writer(), and .seekableStream() interface.
/// The ELF header in the buffer is updated in-place.
/// Assumes that the given buffer contains a valid ELF file.
pub fn removeSectionHeadersAndShstrtab(buffer: anytype) !void {
    const input_elf = try std.elf.Header.read(buffer);

    // Read the raw bytes of the ELF header
    var elf_header_bytes: [@sizeOf(std.elf.Elf64_Ehdr)]u8 align(8) = undefined;
    try buffer.seekableStream().seekTo(0);
    try buffer.reader().readNoEof(&elf_header_bytes);

    // Update the ELF header to remove the section table
    if (input_elf.is_64) {
        const header64 = @ptrCast(*std.elf.Elf64_Ehdr, &elf_header_bytes);
        header64.e_shoff = 0;
        header64.e_shentsize = 0;
        header64.e_shnum = 0;
        header64.e_shstrndx = 0;
    } else {
        const header32 = @ptrCast(*std.elf.Elf32_Ehdr, &elf_header_bytes);
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
    var buf_stream = std.io.fixedBufferStream(test_elf);

    // Remove the section headers and shstrtab
    try removeSectionHeadersAndShstrtab(&buf_stream);

    // Read the modified ELF header
    const modified_elf = try std.elf.Header.read(&buf_stream);

    // Check that the section header table is removed
    try std.testing.expectEqual(@as(u64, 0), modified_elf.shoff);
    try std.testing.expectEqual(@as(u16, 0), modified_elf.shentsize);
    try std.testing.expectEqual(@as(u16, 0), modified_elf.shnum);
    try std.testing.expectEqual(@as(u16, 0), modified_elf.shstrndx);
}

/// Removes sections past the target section from an ELF file, given the target section name, and
/// returns a new ELF file buffer without the removed sections. The section headers and shstrtab
/// are also removed from the new ELF file.
///
/// allocator is used for any memory allocations that this function performs.
/// parse_source should provide the .reader() and .seekableStream() methods, such as a
/// fixed buffer stream or a file stream, containing the input ELF file.
/// target_section_name is the name of the target section, up to which the sections should be
/// retained in the new ELF file.
///
/// Returns a new buffer containing the bytes of the modified ELF file.
/// The caller is responsible for freeing this buffer.
pub fn dropSectionsPastTarget(
    allocator: std.mem.Allocator,
    parse_source: anytype,
    target_section_name: []const u8,
) ![]u8 {
    const input_elf_header = try std.elf.Header.read(parse_source);

    const shstrtab = try readShstrtab(allocator, input_elf_header, parse_source);
    defer allocator.free(shstrtab);

    const target_section_index = try findSectionIndexByName(input_elf_header, parse_source, shstrtab, target_section_name);

    const section_end_offset = try getSectionEndOffset(input_elf_header, parse_source, target_section_index);

    var new_elf_buffer = try allocator.alloc(u8, section_end_offset);
    var new_elf_stream = std.io.fixedBufferStream(new_elf_buffer);

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
    const modified_elf_header = try std.elf.Header.read(&modified_stream);

    // Check that the section headers and shstrtab have been removed
    try std.testing.expectEqual(@as(u16, 0), modified_elf_header.shnum);
    try std.testing.expectEqual(@as(u16, 0), modified_elf_header.shentsize);
    try std.testing.expectEqual(@as(u16, std.elf.SHN_UNDEF), modified_elf_header.shstrndx);
    try std.testing.expectEqual(@as(u64, 0), modified_elf_header.shoff);

    // Check that the ELF file was truncated at the end of the target section
    try std.testing.expectEqual(@as(usize, 192), modified_elf_data.len);
}

/// Removes the target section and sections past it from an ELF file, given the target section name, and
/// returns a new ELF file buffer without the removed sections. The section headers and shstrtab
/// are also removed from the new ELF file.
///
/// allocator is used for any memory allocations that this function performs.
/// parse_source should provide the .reader() and .seekableStream() methods, such as a
/// fixed buffer stream or a file stream, containing the input ELF file.
/// target_section_name is the name of the target section, from which and beyond the sections should be
/// removed in the new ELF file.
///
/// Returns a new buffer containing the bytes of the modified ELF file.
/// The caller is responsible for freeing this buffer.
pub fn dropSectionsFromTarget(
    allocator: std.mem.Allocator,
    parse_source: anytype,
    target_section_name: []const u8,
) ![]u8 {
    const input_elf_header = try std.elf.Header.read(parse_source);

    const shstrtab = try readShstrtab(allocator, input_elf_header, parse_source);
    defer allocator.free(shstrtab);

    const target_section_index = try findSectionIndexByName(input_elf_header, parse_source, shstrtab, target_section_name);

    const target_section_start_offset = try getSectionStartOffset(input_elf_header, parse_source, target_section_index);

    var new_elf_buffer = try allocator.alloc(u8, target_section_start_offset);
    var new_elf_stream = std.io.fixedBufferStream(new_elf_buffer);

    try parse_source.seekableStream().seekTo(0);
    try parse_source.reader().readNoEof(new_elf_buffer);

    try removeSectionHeadersAndShstrtab(&new_elf_stream);

    return new_elf_buffer;
}

test "dropSectionsFromTarget" {
    const allocator = std.testing.allocator;

    // Create an ELF binary with a test section
    const input_elf_data = try createTestElf(allocator, false);
    defer allocator.free(input_elf_data);
    var input_stream = std.io.fixedBufferStream(input_elf_data);

    // Call the dropSectionsFromTarget function
    const target_section_name = ".shstrtab";
    var modified_elf_data = try dropSectionsFromTarget(allocator, &input_stream, target_section_name);
    defer allocator.free(modified_elf_data);
    var modified_stream = std.io.fixedBufferStream(modified_elf_data);

    // Read the modified ELF header
    const modified_elf_header = try std.elf.Header.read(&modified_stream);

    // Check that the section headers and shstrtab have been removed
    try std.testing.expectEqual(@as(u16, 0), modified_elf_header.shnum);
    try std.testing.expectEqual(@as(u16, 0), modified_elf_header.shentsize);
    try std.testing.expectEqual(@as(u16, std.elf.SHN_UNDEF), modified_elf_header.shstrndx);
    try std.testing.expectEqual(@as(u64, 0), modified_elf_header.shoff);

    // Check that the ELF file was truncated at the start of the target section
    try std.testing.expectEqual(@as(usize, 192), modified_elf_data.len);
}
