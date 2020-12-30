const std = @import("std");
const Editor = @import("editor.zig");
const Key = @import("keys.zig").Key;
const term = @import("term.zig");
const Allocator = std.mem.Allocator;

/// Reference to its own
const Prompt = @This();

const PromptResult = union(enum) {
    /// User entered a string that does not contain a known command
    /// i.e. a file path when saving a file
    string: []const u8,
    /// User entered a string that matches a command
    command: void, // TODO: Implement commands
    /// User pressed esc during prompt
    canceled: void,

    /// Frees any memory that was allocated when `run` was executed
    pub fn deinit(self: PromptResult, gpa: *Allocator) void {
        switch (self) {
            .string => |string| gpa.free(string),
            .command => {},
            .canceled => {},
        }
    }
};

/// Blocking function that allows the user to enter
/// information in the prompt
/// NOTE: `deinit` must be ran on the result to free any resources that were allocated
pub fn run(editor: *Editor, gpa: *Allocator) !PromptResult {
    var buf: [128]u8 = undefined;
    var i: usize = 0;

    return while (true) {
        try editor.update();
        const key = try Editor.readInput();

        switch (key) {
            // user pressed <esc> key
            Key.fromChar(27) => break PromptResult.canceled,
            // user pressed enter
            Key.fromChar('\r') => break PromptResult{ .string = try gpa.dupe(u8, buf[0..i]) },
            else => if (key.int() < 128 and !term.isCntrl(key.int()) and i < buf.len) {
                buf[i] = key.char();
                i += 1;
            },
        }
    } else unreachable;
}
