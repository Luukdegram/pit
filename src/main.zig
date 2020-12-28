const std = @import("std");
const editor = @import("editor.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    try editor.run(&gpa.allocator, null);
}
