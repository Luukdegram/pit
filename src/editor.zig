const std = @import("std");
const term = @import("term.zig");
const os = std.os;
const fs = std.fs;
const Allocator = std.mem.Allocator;

const Self = @This();

usingnamespace @import("keys.zig");

width: u16,
height: u16,
x: u16,
y: u16,
text: std.ArrayListUnmanaged(TextRow),
rows: u32,
gpa: *Allocator,

/// Mutable slice of characters
const TextRow = []u8;

/// Starts the editor
pub fn run(gpa: *Allocator, with_file: ?[]const u8) !void {
    try term.init();
    defer term.deinit();

    const size = try term.size();

    var self = Self{
        .width = size.width,
        .height = size.height,
        .x = 0,
        .y = 0,
        .rows = 0,
        .text = std.ArrayListUnmanaged(TextRow){},
        .gpa = gpa,
    };
    defer self.deinit();

    if (with_file) |path| try self.open(path);

    while (true) {
        try self.update();
        const key = try readInput();

        switch (@enumToInt(key)) {
            term.toCtrlKey('q') => {
                try term.sequence("2J");
                try term.sequence("H");
                try term.flush();
                break;
            },
            'h', 'j', 'k', 'l' => self.handleMovement(key),
            else => |c| {
                if (term.isCntrl(c))
                    std.debug.print("{d}\r\n", .{c})
                else
                    std.debug.print("{d} ('{c}')\r\n", .{ c, @truncate(u8, c) });
            },
        }
    }
}

/// Frees the memory of all buffers
fn deinit(self: *Self) void {
    for (self.text.items) |line| self.gpa.free(line);
    self.text.deinit(self.gpa);
    self.* = undefined;
}

/// Blocking function. Reads from stdin and returns the character
/// the user has given as input
fn readInput() !Key {
    return while (true) {
        const esc = @intToEnum(Key, '\x1b');
        const c = term.read() catch |err| switch (err) {
            error.EndOfStream => continue,
            else => return err,
        };

        // handle escape sequences
        if (c == '\x1b') {
            var buf: [3]u8 = undefined;

            buf[0] = term.read() catch |err| switch (err) {
                error.EndOfStream => return esc,
                else => return err,
            };

            buf[1] = term.read() catch |err| switch (err) {
                error.EndOfStream => return esc,
                else => return err,
            };

            if (buf[0] == '[') {
                if (buf[1] >= '0' and buf[1] <= '9') {
                    buf[2] = term.read() catch |err| switch (err) {
                        error.EndOfStream => return esc,
                        else => return err,
                    };

                    if (buf[2] == '~') return Key.fromVt(buf[1]);
                } else return Key.fromEsc(buf[1]);
            } else if (buf[0] == 'O') {
                return switch (buf[1]) {
                    'H' => Key.home,
                    'F' => Key.end,
                    else => esc,
                };
            }
        }

        break @intToEnum(Key, c);
    } else unreachable;
}

/// Clears the screen and sets the cursor at the top
/// as well as write tildes (~) on each row
fn update(self: Self) os.WriteError!void {
    try term.cursor.hide();
    try term.sequence("H");

    try self.drawBuffer();

    try term.cursor.set(self.y, self.x);

    try term.cursor.show();
    try term.flush();
}

/// Draws the contents of the buffer in the terminal
fn drawBuffer(self: Self) os.WriteError!void {
    var i: usize = 0;
    while (i < self.height) : (i += 1) {
        if (i >= self.text.items.len) {
            if (i == self.height / 3)
                try self.startupMessage()
            else
                try term.write("~");

            try term.sequence("K");
            if (i < self.height - 1)
                try term.write("\r\n");
        } else {
            const line = self.text.items[i];

            const len = if (line.len > self.width) self.width else line.len;
            try term.write(line[0..len]);
        }
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
fn handleMovement(self: *Self, key: Key) void {
    switch (key) {
        .arrow_left, @intToEnum(Key, 'h') => self.x -= if (self.x != 0) @as(u16, 1) else 0,
        .arrow_down, @intToEnum(Key, 'j') => self.y += if (self.y != self.height - 1) @as(u16, 1) else 0,
        .arrow_up, @intToEnum(Key, 'k') => self.y -= if (self.y != 0) @as(u16, 1) else 0,
        .arrow_right, @intToEnum(Key, 'l') => self.x += if (self.x != self.width - 1) @as(u16, 1) else 0,
        else => {},
    }
}

/// Loads a file into the buffer
fn open(self: *Self, file_path: []const u8) !void {
    const file = try fs.cwd().openFile(file_path, .{});
    defer file.close();

    // create a temporary buffer of 40Kb where the reader will read into
    var buf: [4096 * 10]u8 = undefined;
    while (try file.reader().readUntilDelimiterOrEof(&buf, '\n')) |line| {
        const text = try self.gpa.dupe(u8, line);
        try self.text.append(self.gpa, text);
    }
}
