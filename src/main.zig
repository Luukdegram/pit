const std = @import("std");
const editor = @import("editor.zig");

pub fn main() !void {
    try editor.run();
}
