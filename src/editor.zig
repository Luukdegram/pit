const std = @import("std");
const term = @import("term.zig");
const os = std.os;

const Self = @This();

usingnamespace @import("keys.zig");

width: u16,
height: u16,
x: u16,
y: u16,

/// Starts the editor
pub fn run() !void {
    try term.init();
    defer term.deinit();

    const size = try term.size();
    const pos = try term.cursorPos();

    var self = Self{ .width = size.width, .height = size.height, .x = pos.row, .y = pos.col };

    while (true) {
        try self.update();
        const c = try term.read();

        switch (c) {
            .ansi => |ansi| switch (ansi) {
                term.toCtrlKey('q') => {
                    try term.sequence("2J");
                    try term.sequence("H");
                    try term.flush();
                    break;
                },
                'h', 'j', 'k', 'l' => self.handleMovement(c),
                else => {
                    if (term.isCntrl(c))
                        std.debug.print("{d}\r\n", .{c})
                    else
                        std.debug.print("{d} ('{c}')\r\n", .{ c, c });
                },
            },
            .key => |key| switch (key) {
                .arrow_up, .arrow_down, .arrow_right, .arrow_left => self.handleMovement(key),
                else => {},
            },
        }
    }
}

/// Blocking function. Reads from stdin and returns the character
/// the user has given as input
pub fn readInput() !InputResult {
    return while (true) {
        const c = term.read() catch |err| switch (err) {
            error.EndOfStream => continue,
            else => return err,
        };

        // handle escape sequences
        if (c == '\x1b') {
            var buf: [3]u8 = undefined;

            buf[0] = term.read() catch |err| switch (err) {
                error.EndOfStream => return InputResult.esc,
                else => return err,
            };

            buf[1] = term.read() catch |err| switch (err) {
                error.EndOfStream => return InputResult.esc,
                else => return err,
            };

            if (buf[0] == '[') {
                if (buf[1] >= '0' and buf[1] <= '9') {
                    buf[2] = term.read() catch |err| switch (err) {
                        error.EndOfStream => return InputResult.esc,
                        else => return err,
                    };

                    if (buf[2] == '~') return InputResult{ .key = Key.fromVt(buf[1]) };
                } else return InputResult{ .key = Key.fromEsc(buf[1]) };
            } else if (buf[0] == 'O') {
                return switch (buf[1]) {
                    'H' => InputResult{ .key = Key.home },
                    'F' => InputResult{ .key = Key.end },
                    else => InputResult.esc,
                };
            }
        }

        break InputResult{ .ansi = c };
    } else unreachable;
}

/// Clears the screen and sets the cursor at the top
/// as well as write tildes (~) on each row
fn update(self: Self) os.WriteError!void {
    try term.hideCursor();
    try term.sequence("H");

    try self.drawBuffer();

    try term.setCursor(self.y, self.x);

    try term.showCursor();
    try term.flush();
}

fn drawBuffer(self: Self) os.WriteError!void {
    var i: usize = 0;
    while (i < self.height) : (i += 1) {
        if (i == self.height / 3)
            try self.startupMessage()
        else
            try term.write("~");

        try term.sequence("K");
        if (i < self.height - 1)
            try term.write("\r\n");
    }
}

/// Shows the startup message if no file buffer was opened
fn startupMessage(self: Self) os.WriteError!void {
    const message = "Pit editor -- version 0.0.1";
    var padding = (self.width - message.len) / 2;
    if (padding > 0) {
        try term.write("~");
        padding -= 1;
    }
    while (padding > 0) : (padding -= 1) {
        try term.write(" ");
    }
    try term.write(message);
}

/// Checks the input character found, and handles the corresponding movement
fn handleMovement(self: *Self, char: u8) void {
    switch (char) {
        'h' => self.x -= if (self.x != 0) @as(u16, 1) else 0,
        'j' => self.y += if (self.y != self.height - 1) @as(u16, 1) else 0,
        'k' => self.y -= if (self.y != 0) @as(u16, 1) else 0,
        'l' => self.x += if (self.x != self.width - 1) @as(u16, 1) else 0,
        else => {},
    }
}
