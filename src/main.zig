const std = @import("std");
const Editor = @import("Editor.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = &gpa.allocator;

    var it = std.process.args();

    // skip first arg as it contains the executable
    const exe = it.next(alloc);
    alloc.free(try exe.?);

    const possible_path = it.next(alloc);
    var path: ?[]const u8 = null;

    if (possible_path) |p| path = try p;
    defer if (path) |p| alloc.free(p);

    // finally, run the editor
    try Editor.run(alloc, path);
}
