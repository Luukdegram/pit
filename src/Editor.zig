const std = @import("std");
const term = @import("term.zig");
const TextBuffer = @import("TextBuffer.zig");
const StatusBar = @import("StatusBar.zig");
const os = std.os;
const fs = std.fs;
const Allocator = std.mem.Allocator;

const Self = @This();

/// Error represents any error that can occur
pub const Error = error{OutOfMemory} || os.WriteError;

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
/// The state of the editor, this can either be 'select',
/// where the user can jump through the file and perform select options,
/// or 'insert' in which the user can actually insert new characters
/// The default is 'select'
state: enum { select, insert } = .select,
/// Status bar that shows a status line, optional message and can trigger a prompt
status_bar: *StatusBar,

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
        .status_bar = undefined,
    };
    defer self.deinit();

    self.status_bar = &StatusBar.init(&self);

    // Open the file path if given. If not, open a new clean TextBuffer
    if (with_file) |path| try self.open(path) else {
        try self.buffers.append(gpa, TextBuffer.init(null));
    }

    while (!should_quit.load(.SeqCst)) {
        try self.update();
        const key = try self.readInput();

        if (self.state == .select)
            try self.onSelect(key)
        else
            try self.onInsert(key);
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
pub fn buffer(self: *Self) *TextBuffer {
    std.debug.assert(self.buffers.items.len > 0);
    std.debug.assert(self.active < self.buffers.items.len);
    return &self.buffers.items[self.active];
}

/// Blocking function. Reads from stdin and returns the character
/// the user has given as input
pub fn readInput(self: Self) !Key {
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

/// Handles input when the editor's state is 'select'
fn onSelect(self: *Self, key: Key) (Error || TextBuffer.SaveError || os.ReadError || error{EndOfStream})!void {
    switch (key) {
        Key.fromChar('h'),
        Key.fromChar('j'),
        Key.fromChar('k'),
        Key.fromChar('l'),
        .arrow_down,
        .arrow_left,
        .arrow_right,
        .arrow_up,
        .home,
        .end,
        .page_up,
        .page_down,
        => self.moveCursor(key),
        Key.fromChar(term.toCtrlKey('q')) => try onQuit(),
        Key.fromChar(term.toCtrlKey('s')) => try self.onSave(),
        Key.fromChar('i') => self.state = .insert,
        Key.fromChar(':') => {
            const cmd = try self.status_bar.prompt(self.gpa);
            defer cmd.deinit(self.gpa);
            try self.buffer().get(self.text_y).appendSlice(self.gpa, self.text_x, cmd.string);
        },
        else => {},
    }
}

/// Handles the input when the editor's state is 'insert'
fn onInsert(self: *Self, key: Key) Error!void {
    switch (key) {
        // enter
        Key.fromChar('\r') => {
            const buf = self.buffer();
            if (self.text_x == 0)
                try buf.insert(self.gpa, self.text_y, "")
            else {
                const row = buf.get(self.text_y);
                try buf.insert(self.gpa, self.text_y + 1, row.raw.items[self.text_x..row.len()]);
                try row.resize(self.gpa, self.text_x);
            }

            // set cursor to start of newline
            self.text_y += 1;
            self.text_x = 0;
        },
        // backspace
        Key.fromChar(127) => {
            const buf = self.buffer();

            if (self.text_x > 0) {
                try buf.get(self.text_y).remove(self.gpa, self.text_x - 1);
                self.text_x -= 1;
            } else if (self.text_y > 0) {
                self.text_x = buf.get(self.text_y - 1).len();
                try buf.delete(self.gpa, self.text_y);
                self.text_y -= 1;
            }
        },
        // <esc> key
        Key.fromChar(27) => self.state = .select,
        // anything else
        else => if (key.int() <= 256 and !term.isCntrl(key.char())) {
            const buf = self.buffer();

            if (self.text_y == buf.len()) {
                try buf.insert(self.gpa, self.text_y, "");
            }

            const row = buf.get(self.text_y);

            try row.insert(self.gpa, self.text_x, key.char());

            self.text_x += 1;
        },
    }
}

/// onQuit empties the terminal window
fn onQuit() Error!void {
    try term.sequence("2J");
    try term.sequence("H");
    try term.flush();

    should_quit.store(true, .SeqCst);
}

/// Saves the current Buffer to a file
fn onSave(self: *Self) !void {
    self.buffer().save() catch |err| switch (err) {
        error.UnknownPath => @panic("TODO: Implement prompt to ask for file_path"),
        else => return err,
    };
}

/// Clears the screen and sets the cursor at the top
/// as well as write tildes (~) on each row
pub fn update(self: *Self) Error!void {
    try self.scroll();
    try term.cursor.hide();
    try term.sequence("H");

    try self.render();
    try self.status_bar.render();

    const y = self.text_y - self.row_offset;
    const x = self.view_x - self.col_offset;
    try term.cursor.set(y + 1, x + 1);

    try term.cursor.show();
    try term.flush();
}

/// Draws the contents of the buffer in the terminal
fn render(self: *Self) Error!void {
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
        try term.write("\r\n");
    }
}

/// Shows the startup message if no file buffer was opened
fn startupMessage(self: Self) Error!void {
    const message = "Pit editor -- version 0.0.0";
    var padding = (self.width - message.len) / 2;
    if (padding > 0) {
        try term.write("~");
        padding -= 1;
    }
    while (padding > 0) : (padding -= 1)
        try term.write(" ");

    try term.write(message);
}

/// Checks the input character found, and handles the corresponding movement
fn moveCursor(self: *Self, key: Key) void {
    var current_row = if (self.text_y >= self.buffer().len())
        null
    else
        self.buffer().get(self.text_y);

    switch (key) {
        .home => self.text_x = 0,
        .end => self.text_x = if (current_row) |r| r.len() else 0,
        .arrow_left, Key.fromChar('h') => {
            if (self.text_x != 0)
                self.text_x -= 1
            else if (self.text_y > 0) {
                self.text_y -= 1;
                self.text_x = self.buffer().get(self.text_y).len();
            }
        },
        .arrow_down, Key.fromChar('j') => {
            self.text_y += @boolToInt(self.text_y < self.buffer().len());
        },
        .arrow_up, Key.fromChar('k') => {
            self.text_y -= @boolToInt(self.text_y != 0);
        },
        .arrow_right, Key.fromChar('l') => {
            if (current_row) |row| {
                if (self.text_x < row.len())
                    self.text_x += 1
                else if (self.text_x == row.len()) {
                    self.text_y += 1;
                    self.text_x = 0;
                }
            }
        },
        .page_up, .page_down => {
            if (key == .page_up)
                self.text_y = self.row_offset
            else {
                self.text_y = self.row_offset + self.height - 1;
                if (self.text_y > self.buffer().len()) self.text_y = self.buffer().len();
            }

            var i = self.height;
            while (i > 0) : (i -= 1) self.moveCursor(if (key == .page_up) .arrow_up else .arrow_down);
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
    var text_buffer = TextBuffer.init(file_path);
    errdefer text_buffer.deinit(self.gpa);

    while (try file.reader().readUntilDelimiterOrEof(&buf, '\n')) |line| {
        // Check if the line contains a '\r'. If true, cut it off
        const real_line = blk: {
            if (line.len == 0) break :blk line;

            const idx = line.len - 1;
            break :blk if (line[idx] == '\r') line[0..idx] else line;
        };

        // append the line to our text buffer
        try text_buffer.insert(self.gpa, text_buffer.len(), real_line);
    }

    try self.buffers.append(self.gpa, text_buffer);
    self.active = @intCast(u32, self.buffers.items.len) - 1;
    self.state = .select;
}

/// Handle automatic scrolling based on cursor position
fn scroll(self: *Self) Error!void {
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