const std = @import("std");

pub fn main() !void {
    try std.io.getStdOut().writer().writeAll("Hello World!\n");
}
