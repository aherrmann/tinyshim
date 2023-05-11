const std = @import("std");
const mem = std.mem;
const os = std.os;

const SimplePageAllocator = struct {
    pub fn alloc(count: usize) ![]align(mem.page_size) u8 {
        const size = mem.alignForward(count, mem.page_size);
        const ptr = try os.mmap(null, size, os.PROT.READ | os.PROT.WRITE, os.MAP.PRIVATE | os.MAP.ANONYMOUS, -1, 0);
        return ptr;
    }

    pub fn free(ptr: []align(mem.page_size) u8) void {
        os.munmap(ptr);
    }
};

fn StackOrPageBuffer(comptime stack_size: usize) type {
    return union(enum) {
        const Self = @This();

        stack_buffer: [stack_size]u8,
        page_buffer: []u8,

        pub fn init(required_size: usize) !Self {
            if (required_size <= stack_size) {
                return Self{ .stack_buffer = undefined };
            } else {
                return Self{ .page_buffer = try SimplePageAllocator.alloc(required_size) };
            }
        }

        pub fn deinit(self: *Self) void {
            switch (self.*) {
                .stack_buffer => {},
                .page_buffer => |ptr| SimplePageAllocator.free(@alignCast(mem.page_size, ptr)),
            }
        }

        pub fn get(self: *Self) []u8 {
            switch (self.*) {
                .stack_buffer => |*slice| return slice,
                .page_buffer => |ptr| return ptr,
            }
        }
    };
}

test "StackOrPageBuffer stack allocated" {
    const stack_size = 4096;
    const required_size = stack_size;

    var buf = try StackOrPageBuffer(stack_size).init(required_size);
    defer buf.deinit();

    // Ensure the buffer has the correct size
    try std.testing.expect(required_size <= buf.get().len);

    // Ensure the buffer is stack allocated
    try std.testing.expectEqualStrings("stack_buffer", @tagName(buf));

    // Ensure the buffer is persistent.
    const msg = "Hello world";
    std.mem.copy(u8, buf.get(), msg);
    try std.testing.expectEqualStrings(msg, buf.get()[0..msg.len]);
}

test "StackOrPageBuffer page allocated" {
    const required_size = 7000;
    const stack_size = 4096;

    var buf = try StackOrPageBuffer(stack_size).init(required_size);
    defer buf.deinit();

    // Ensure the buffer has the correct size
    try std.testing.expect(required_size <= buf.get().len);

    // Ensure the buffer is page allocated
    try std.testing.expectEqualStrings("page_buffer", @tagName(buf));

    // Ensure the buffer is persistent.
    const msg = "Hello world";
    std.mem.copy(u8, buf.get(), msg);
    try std.testing.expectEqualStrings(msg, buf.get()[0..msg.len]);
}

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
