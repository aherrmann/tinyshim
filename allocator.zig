const std = @import("std");
const mem = std.mem;

const SimpleBumpAllocator = struct {
    buffer: []u8,
    cursor: usize,

    fn init(buffer: []u8) SimpleBumpAllocator {
        return SimpleBumpAllocator{
            .buffer = buffer,
            .cursor = 0,
        };
    }

    fn alloc(self: *SimpleBumpAllocator, comptime T: type, n: usize) ![]T {
        const align_offset = mem.alignForward(self.cursor, @alignOf(T));
        const required_size = n * @sizeOf(T);
        const new_cursor = align_offset + required_size;

        if (new_cursor > self.buffer.len) {
            return error.OutOfMemory;
        }

        const result = @ptrCast([*]T, @alignCast(@alignOf(T), self.buffer[align_offset..new_cursor]))[0..n];
        self.cursor = new_cursor;

        return result;
    }
};

test "bump allocator" {
    const SIZE = 4096;
    var buffer: [SIZE]u8 = undefined;
    var allocator = SimpleBumpAllocator.init(&buffer);

    // allocate one byte
    var one = try allocator.alloc(u8, 1);
    one[0] = 42;
    try std.testing.expectEqual(@as(u8, 42), one[0]);

    // allocate ten bytes
    var ten = try allocator.alloc(u8, 10);
    ten[9] = 84;
    try std.testing.expectEqual(@as(u8, 84), ten[9]);

    // allocate a hundred 64-bit unsigned integers (taking alignment into account)
    var hundred = try allocator.alloc(u64, 100);
    hundred[99] = 21;
    try std.testing.expectEqual(@as(u64, 21), hundred[99]);

    // try to allocate beyond the buffer.
    const used_space = mem.alignForward((one.len + ten.len) * @sizeOf(u8), @alignOf(u64)) + hundred.len * @sizeOf(u64);
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, SIZE - used_space + 1));
}
