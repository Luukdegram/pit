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

/// Returns a new instance of `StatusBar`
pub fn init(editor: *Editor) StatusBar {
    // decrease the height by 1 for the status line
    editor.height -= 1;
    return .{ .editor = editor, .message = null };
}

/// Blocking function that allows the user to enter
/// information in the prompt
/// NOTE: `deinit` must be called on the result to free any resources that were allocated
pub fn prompt(self: *StatusBar, gpa: *Allocator, on_input: ?fn ([]const u8, Key) void) !PromptResult {
    var buf: [128]u8 = undefined;
    var i: usize = 0;

    return while (true) {
        try self.editor.update();
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
            Key.fromChar('\r') => break PromptResult{ .string = try gpa.dupe(u8, buf[0..i]) },

            // regular text input
            else => if (key.int() < 128 and !term.isCntrl(key.int()) and i < buf.len) {
                buf[i] = key.char();
                i += 1;
            },
        }
    } else unreachable;
}

/// Renders the status bar
pub fn render(self: *StatusBar) !void {
    try self.statusMessage();
    try self.statusLine();
}

/// Draws a status bar with inverted colors
fn statusLine(self: *StatusBar) !void {
    // First invert the colors
    try term.sequence("7m");

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

    var i: usize = 0;
    while (i < self.editor.width - status_msg.len) : (i += 1)
        try term.write(" ");

    // write our status message at the end
    try term.write(status_msg);

    // Revert to regular colors
    try term.sequence("m");
}

/// Renders a status message if set
fn statusMessage(self: StatusBar) !void {
    if (self.message) |msg| {
        try term.write(msg);
        try term.sequence("K");
        try term.write("\r\n");
    }
}

/// Enables a message in the editor view with the given `message`
pub fn showMessage(self: *StatusBar, message: []const u8) void {
    // decrease the terminal buffer height by 1 as we use that space
    // to write our status message but only if no message is being displayed
    if (self.message == null)
        self.editor.height -= 1;
    self.message = message;
}

/// Hides the status message if it's currently enabled
pub fn hideMessage(self: *StatusBar) void {
    // only if enabled
    if (self.message) |_| {
        self.message = null;

        // Increase the height back by 1 as we don't require
        // the terminal space any longer
        self.editor.height += 1;
    }
}
