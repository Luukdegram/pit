const std = @import("std");
const TextBuffer = @import("TextBuffer.zig");
const Allocator = std.mem.Allocator;

var buffer: ?TextBuffer = null;

/// Creates a new 'debug' buffer that is available globally
pub fn init(gpa: *Allocator) void {
    buffer = TextBuffer.init(gpa, null);
    buffer.?.kind = .debug;
}

/// Frees all resources of the debug buffer
pub fn deinit() void {
    get().deinit();
}

/// Logs a new message to the debug buffer
pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime fmt: []const u8,
    args: anytype,
) void {
    const level_txt = switch (message_level) {
        .emerg => "emergency",
        .alert => "alert",
        .crit => "critical",
        .err => "error",
        .warn => "warning",
        .notice => "notice",
        .info => "info",
        .debug => "debug",
    };
    const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";

    nosuspend get().insert(u21, get().len(), &[_]u21{}) catch return;
    nosuspend writer().print(level_txt ++ prefix2 ++ fmt, args) catch return;
}

/// Returns a pointer to `buffer` and asserts it's initialized
/// Always use this when trying to access the raw `buffer` object
///
/// NOTE: Accessing the raw `buffer` object is only ment for the editor
/// outside that, the writer() interface should be used
pub fn get() *TextBuffer {
    std.debug.assert(buffer != null);
    return &buffer.?;
}

/// Out of Memory error when appending to the debug buffer
pub const Error = error{ OutOfMemory, InvalidUtf8 };

/// Writer interface
pub const Writer = std.io.Writer(*TextBuffer, Error, write);

/// Returns a writer to the debug buffer
///
/// NOTE: prefer using std.log above this as it is overwritten to use this internal debug buffer
/// and will create new lines automatically as the writer() interface will write
/// to the latest `TextRow` that was created
pub fn writer() Writer {
    return .{ .context = get() };
}

/// writes the given bytes to the debug buffer after encoding it to utf8
fn write(ctx: *TextBuffer, bytes: []const u8) !usize {
    if (ctx.len() == 0)
        try buffer.?.insert(u21, 0, &[_]u21{});

    const row = ctx.get(ctx.len() - 1);

    var len: usize = 0;
    var it = (try std.unicode.Utf8View.init(bytes)).iterator();
    while (it.nextCodepoint()) |cp| {
        try row.insert(ctx.gpa, row.len(), cp);
        len += 1;
    }

    return len;
}
