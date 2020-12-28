const std = @import("std");
const term = @import("term.zig");
const TextBuffer = @import("TextBuffer.zig");
const os = std.os;
const fs = std.fs;
const Allocator = std.mem.Allocator;

const Self = @This();

usingnamespace @import("keys.zig");

width: u16,
height: u16,
x: u16 = 0,
y: u16 = 0,
gpa: *Allocator,
row_offset: u32 = 0,
col_offset: u32 = 0,
buffers: std.ArrayListUnmanaged(TextBuffer),
active: usize = 0,

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
        .gpa = gpa,
        .buffers = std.ArrayListUnmanaged(TextBuffer){},
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
    for (self.buffers.items) |*b| b.deinit(self.gpa);
    self.buffers.deinit(self.gpa);
    self.* = undefined;
}

/// Returns the currently active TextBuffer
/// Asserts atleast 1 buffer exists and the
/// `active` index is not out of bounds
fn buffer(self: *Self) *TextBuffer {
    std.debug.assert(self.buffers.items.len > 0);
    std.debug.assert(self.active < self.buffers.items.len);
    return &self.buffers.items[self.active];
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
fn update(self: *Self) os.WriteError!void {
    try self.scroll();
    try term.cursor.hide();
    try term.sequence("H");

    try self.drawBuffer();

    const y: u32 = self.y - self.row_offset;
    const x: u32 = self.x - self.col_offset;
    try term.cursor.set(y + 1, x + 1);

    try term.cursor.show();
    try term.flush();
}

/// Draws the contents of the buffer in the terminal
fn drawBuffer(self: *Self) os.WriteError!void {
    var i: usize = 0;
    while (i < self.height) : (i += 1) {
        const offset = i + self.row_offset;
        if (offset >= self.buffer().len()) {
            if (self.buffer().len() == 0 and
                i == self.height / 3)
                try self.startupMessage()
            else
                try term.write("~");
        } else {
            const line = self.buffer().get(offset);

            const len = blk: {
                if (line.len() - self.col_offset < 0) break :blk 0;
                var line_len = line.len() - self.col_offset;

                if (line_len > self.width) line_len = self.width;
                break :blk line_len;
            };
            try term.write(line.renderable[0..len]);
        }

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
fn handleMovement(self: *Self, key: Key) void {
    switch (key) {
        .arrow_left, @intToEnum(Key, 'h') => {
            if (self.x != 0)
                self.x -= 1
            else if (self.y > 0) {
                self.y -= 1;
                self.x = @intCast(u16, self.buffer().get(self.y).len());
            }
        },
        .arrow_down, @intToEnum(Key, 'j') => {
            if (self.y < self.buffer().len()) self.y += 1;
        },
        .arrow_up, @intToEnum(Key, 'k') => {
            if (self.y != 0) self.y -= 1;
        },
        .arrow_right, @intToEnum(Key, 'l') => {
            const row = if (self.y >= self.buffer().len()) null else self.buffer().get(self.y);
            if (row != null and self.x < row.?.len())
                self.x += 1
            else if (row != null and self.x == row.?.len()) {
                self.y += 1;
                self.x = 0;
            }
        },
        else => {},
    }

    const row = if (self.y >= self.buffer().len()) null else self.buffer().get(self.y);
    const len = if (row) |r| @intCast(u16, r.len()) else 0;
    if (self.x > len)
        self.x = len;
}

/// Loads a file into the buffer
fn open(self: *Self, file_path: []const u8) !void {
    const file = try fs.cwd().openFile(file_path, .{});
    defer file.close();

    // create a temporary buffer of 40Kb where the reader will read into
    var buf: [4096 * 10]u8 = undefined;
    var text_buffer = TextBuffer.init();
    errdefer text_buffer.deinit(self.gpa);

    while (try file.reader().readUntilDelimiterOrEof(&buf, '\n')) |line| {
        // Check if the line contains a '\r'. If true, cut it off
        const real_line = blk: {
            if (line.len == 0) break :blk line;

            const idx = line.len - 1;
            break :blk if (line[idx] == '\r') line[0..idx] else line;
        };

        // append the line to our text buffer
        const text = try self.gpa.dupe(u8, real_line);
        var row = TextBuffer.TextRow.init(text);
        try row.update(self.gpa);
        try text_buffer.append(self.gpa, row);
    }

    try self.buffers.append(self.gpa, text_buffer);
    self.active = self.buffers.items.len - 1;
}

/// Handle automatic scrolling based on cursor position
fn scroll(self: *Self) os.WriteError!void {
    if (self.y < self.row_offset) {
        self.row_offset = self.y;
    }
    if (self.y >= self.row_offset + self.height) {
        self.row_offset = self.y - self.height + 1;
    }
    if (self.x < self.col_offset) {
        self.col_offset = self.x;
    }
    if (self.x >= self.col_offset + self.width) {
        self.col_offset = self.x - self.width + 1;
    }
}
