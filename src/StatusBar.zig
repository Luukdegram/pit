const std = @import("std");
const Editor = @import("Editor.zig");
const Key = @import("keys.zig").Key;
const term = @import("term.zig");
const Allocator = std.mem.Allocator;

/// Reference to its own
const StatusBar = @This();

/// Reference to the editor so we can manipulate its
/// view size as well as take over the loop when triggering
/// a prompt
editor: *Editor,
/// A message to show to the user
message: ?[]const u8,

const PromptResult = union(enum) {
    /// User entered a string that does not contain a known command
    /// i.e. a file path when saving a file
    string: []const u21,
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

/// Returns a new instance of `StatusBar`
pub fn init(editor: *Editor) StatusBar {
    return .{ .editor = editor, .message = null };
}

/// Blocking function that allows the user to enter
/// information in the prompt
/// NOTE: `deinit` must be called on the result to free any resources that were allocated
pub fn prompt(self: *StatusBar, gpa: *Allocator, on_input: ?fn ([]const u21, Key) void) !PromptResult {
    var buf: [128]u21 = undefined;
    var i: u32 = 0;

    self.editor.height -= 1;
    defer self.editor.height += 1;

    // old cursor position so we can return to it when done
    const old_pos = try term.cursor.getPos();

    // the y position where the cursor will be
    const y = self.editor.height + 2 + @boolToInt(self.message != null);

    return while (true) {
        try self.editor.update(.ignore);

        // used to check how many spaces we need to write after maybe input
        var space_left = self.editor.width;

        // First write the user's input to the prompt line
        for (buf[0..i]) |cp| {
            var cp_buf: [4]u8 = undefined;
            const cp_len = std.unicode.utf8Encode(cp, &cp_buf) catch unreachable;

            try term.write(cp_buf[0..cp_len]);
            space_left -= utf8Len(cp);
        }

        // write the final spaces that are unwritten to clear the line
        while (space_left > 0) : (space_left -= 1) try term.write(" ");
        try term.cursor.set(y, i + 1);
        try term.flush();

        const key = try self.editor.readInput();

        defer if (on_input) |callback| callback(buf[0..i], key);

        switch (key) {
            // user pressed <esc> key
            Key.fromChar(27) => break PromptResult.canceled,

            // User presses delete or backspace button
            .delete,
            Key.fromChar(term.toCtrlKey('h')),
            Key.fromChar(127),
            => i -= @boolToInt(i > 0),

            // user pressed enter
            Key.fromChar('\r') => break PromptResult{ .string = try gpa.dupe(u21, buf[0..i]) },

            // regular text input
            else => if (key.int() < 128 and !term.isCntrl(key.int()) and i < buf.len) {
                buf[i] = @intCast(u21, key.int());
                i += 1;
            },
        }
    } else unreachable;
}

/// Draws a status bar with inverted colors
pub fn render(self: *StatusBar) !void {
    // First invert the colors
    try term.sequence("7m");

    if (self.message) |msg| try term.write(msg);

    const dirty_message = if (self.editor.buffer().isDirty())
        " +"
    else
        "";

    const file_name = self.editor.buffer().file_path orelse "[Empty buffer]";

    var buf: [4096 * 10]u8 = undefined;
    const status_msg = try std.fmt.bufPrint(&buf, "{s}{s} {d}:{d}", .{
        file_name,
        dirty_message,
        self.editor.text_y + 1,
        self.editor.text_x + 1,
    });

    const whitespace_len = self.editor.width - status_msg.len - if (self.message) |msg|
        msg.len
    else
        0;

    var i: usize = 0;
    while (i < whitespace_len) : (i += 1)
        try term.write(" ");

    // write our status message at the end
    try term.write(status_msg);

    // Revert to regular colors
    try term.sequence("m");
}

/// Enables a message in the editor view with the given `message`
pub fn showMessage(self: *StatusBar, message: []const u8) void {
    self.message = message;
}

/// Hides the status message if it's currently enabled
pub fn hideMessage(self: *StatusBar) void {
    self.message = null;
}

/// Returns the length that the given codepoint requires on the screen
fn utf8Len(codepoint: u21) u3 {
    var cp = codepoint;
    var width: u3 = 0;
    return while (true) {
        width += 1;
        cp >>= 8;

        if (cp == 0) break width;
    } else unreachable;
}
