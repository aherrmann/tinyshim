const std = @import("std");
const elf_util = @import("elf_util.zig");

test ".payload section at end of file" {
    const allocator = std.testing.allocator;

    const args = try std.process.argsAlloc(allocator);
    defer allocator.free(args);

    try std.testing.expectEqual(@as(usize, 2), args.len);
    const shim_path = args[1];

    const shim_file = try std.fs.cwd().openFile(shim_path, .{});
    defer shim_file.close();

    const shim_elf_header = try std.elf.Header.read(shim_file);

    const shstrtab = try elf_util.readShstrtab(allocator, shim_elf_header, shim_file);
    defer allocator.free(shstrtab);

    // Find the .payload section.
    const payload_name: []const u8 = ".payload";
    var sh_iter = shim_elf_header.section_header_iterator(shim_file);
    find_payload: {
        while (try sh_iter.next()) |shdr| {
            const current_section_name = std.mem.sliceTo(shstrtab[shdr.sh_name..], 0);
            if (std.mem.eql(u8, current_section_name, payload_name)) {
                break :find_payload;
            }
        }
        return error.PayloadSectionNotFound;
    }

    // Test that any following sections can be stripped,
    // i.e. that the payload section is effectively at the end of the file.
    const accepted_names = [_][]const u8{
        ".comment",
        ".shstrtab",
    };
    outer: while (try sh_iter.next()) |shdr| {
        const current_section_name = std.mem.sliceTo(shstrtab[shdr.sh_name..], 0);
        for (accepted_names) |accepted_name| {
            if (std.mem.eql(u8, current_section_name, accepted_name)) {
                continue :outer;
            }
        }
        std.debug.print("\nUnaccepted section name {s}\n", .{current_section_name});
        return error.UnacceptedSectionName;
    }
}
