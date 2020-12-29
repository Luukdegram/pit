const std = @import("std");
const term = @import("term.zig");
const TextBuffer = @import("TextBuffer.zig");
const os = std.os;
const fs = std.fs;
const Allocator = std.mem.Allocator;

const Self = @This();

usingnamespace @import("keys.zig");

/// Width of the terminal window
width: u16,
/// Height of the terminal window
height: u16,
/// The cursor's x position in the raw text
text_x: u32 = 0,
/// The cursor's y position in the raw text
text_y: u32 = 0,
/// The cursor's x position that is being rendered
view_x: u32 = 0,
/// The cursor's y position that is being rendered
view_y: u32 = 0,
/// Editor's general purpose allocator
gpa: *Allocator,
/// The scrolling row offset of the view inside the buffer
row_offset: u32 = 0,
/// The scrolling column offset of the view inside the buffer
col_offset: u32 = 0,
/// Currently active buffers
buffers: std.ArrayListUnmanaged(TextBuffer),
/// The index of the currently active buffer
active: u32 = 0,

/// Atomic bool used to shutdown the editor safely
var should_quit = std.atomic.Bool.init(false);

/// Starts the editor
/// leaving `with_file` null will open the welcome buffer
/// rather than a file
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

    while (!should_quit.load(.SeqCst)) {
        try self.update();
        const key = try readInput();

        try self.onInput(key);
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

                    if (buf[2] == '~') return Key.fromEscChar(buf[1]);
                } else return Key.fromEscChar(buf[1]);
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

fn onInput(self: *Self, key: Key) os.WriteError!void {
    switch (key) {
        Key.fromChar('h'),
        Key.fromChar('j'),
        Key.fromChar('k'),
        Key.fromChar('l'),
        .arrow_down,
        .arrow_left,
        .arrow_right,
        .arrow_up,
        => self.moveCursor(key),
        Key.fromChar(term.toCtrlKey('q')) => try onQuit(),
        else => {},
    }
}

/// onQuit empties the terminal window
fn onQuit() os.WriteError!void {
    try term.sequence("2J");
    try term.sequence("H");
    try term.flush();

    should_quit.store(true, .SeqCst);
}

/// Clears the screen and sets the cursor at the top
/// as well as write tildes (~) on each row
fn update(self: *Self) os.WriteError!void {
    try self.scroll();
    try term.cursor.hide();
    try term.sequence("H");

    try self.drawBuffer();

    const y = self.text_y - self.row_offset;
    const x = self.view_x - self.col_offset;
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
                if (line.renderLen() - self.col_offset < 0) break :blk 0;
                var line_len = line.renderLen() - self.col_offset;

                if (line_len > self.width) line_len = self.width;
                break :blk line_len;
            };
            try term.write(line.renderable[self.col_offset .. self.col_offset + len]);
        }

        try term.sequence("K");
        if (i < self.height - 1)
            try term.write("\r\n");
    }
}

/// Shows the startup message if no file buffer was opened
fn startupMessage(self: Self) os.WriteError!void {
    const message = "Pit editor -- version 0.0.0";
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
fn moveCursor(self: *Self, key: Key) void {
    var current_row = if (self.text_y >= self.buffer().len())
        null
    else
        self.buffer().get(self.text_y);

    switch (key) {
        .arrow_left, @intToEnum(Key, 'h') => {
            if (self.text_x != 0)
                self.text_x -= 1
            else if (self.text_y > 0) {
                self.text_y -= 1;
                self.text_x = self.buffer().get(self.text_y).len();
            }
        },
        .arrow_down, @intToEnum(Key, 'j') => {
            self.text_y += @boolToInt(self.text_y < self.buffer().len());
        },
        .arrow_up, @intToEnum(Key, 'k') => {
            self.text_y -= @boolToInt(self.text_y != 0);
        },
        .arrow_right, @intToEnum(Key, 'l') => {
            if (current_row) |row| {
                if (self.text_x < row.len())
                    self.text_x += 1
                else if (self.text_x == row.len()) {
                    self.text_y += 1;
                    self.text_x = 0;
                }
            }
        },
        else => {},
    }

    current_row = if (self.text_y >= self.buffer().len()) null else self.buffer().get(self.text_y);
    const len = if (current_row) |r| r.len() else 0;
    if (self.text_x > len)
        self.text_x = len;
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
        var row = try TextBuffer.TextRow.init(text, self.gpa);
        try row.update(self.gpa);
        try text_buffer.append(self.gpa, row);
    }

    try self.buffers.append(self.gpa, text_buffer);
    self.active = @intCast(u32, self.buffers.items.len) - 1;
}

/// Handle automatic scrolling based on cursor position
fn scroll(self: *Self) os.WriteError!void {
    self.view_x = if (self.text_y < self.buffer().len())
        self.buffer().get(self.text_y).getIdx(self.text_x)
    else
        0;

    if (self.text_y < self.row_offset) {
        self.row_offset = self.text_y;
    }
    if (self.text_y >= self.row_offset + self.height) {
        self.row_offset = self.text_y - self.height + 1;
    }
    if (self.view_x < self.col_offset) {
        self.col_offset = self.view_x;
    }
    if (self.view_x >= self.col_offset + self.width) {
        self.col_offset = self.view_x - self.width + 1;
    }
}
