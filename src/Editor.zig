const std = @import("std");
const term = @import("term.zig");
const TextBuffer = @import("TextBuffer.zig");
const StatusBar = @import("StatusBar.zig");
const os = std.os;
const fs = std.fs;
const Allocator = std.mem.Allocator;

const Editor = @This();

/// Error represents any error that can occur
pub const Error = error{
    OutOfMemory,
    InvalidUtf8,
} || os.WriteError;

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

    var self = Editor{
        .width = size.width,
        // -1 height for status line
        .height = size.height - 1,
        .gpa = gpa,
        .buffers = std.ArrayListUnmanaged(TextBuffer){},
        .status_bar = undefined,
    };
    defer self.deinit();

    self.status_bar = &StatusBar.init(&self);

    // Open the file path if given. If not, open a new clean TextBuffer
    if (with_file) |path| try self.open(try gpa.dupe(u8, path)) else {
        try self.buffers.append(gpa, TextBuffer.init(gpa, null));
    }

    while (!should_quit.load(.SeqCst)) {
        try self.update(.update);
        const key = try self.readInput();

        if (self.state == .select)
            try self.onSelect(key)
        else
            try self.onInsert(key);

        const new_size = try term.size();
        self.height = new_size.height - 1;
        self.width = new_size.width;
    }
}

/// Frees the memory of all buffers
fn deinit(self: *Editor) void {
    for (self.buffers.items) |*b| {
        if (b.file_path) |p| self.gpa.free(p);
        b.deinit();
    }
    self.buffers.deinit(self.gpa);
    self.* = undefined;
}

/// Returns the currently active TextBuffer
/// Asserts atleast 1 buffer exists and the
/// `active` index is not out of bounds
pub fn buffer(self: *Editor) *TextBuffer {
    std.debug.assert(self.buffers.items.len > 0);
    std.debug.assert(self.active < self.buffers.items.len);
    return &self.buffers.items[self.active];
}

/// Blocking function. Reads from stdin and returns the character
/// the user has given as input
pub fn readInput(self: Editor) !Key {
    return while (true) {
        const esc = @intToEnum(Key, '\x1b');
        var buf: [4]u8 = undefined;

        const len = try term.reader().read(&buf);
        if (len == 0) continue;

        if (std.mem.eql(u8, &buf, "\x1b")) return esc;

        // handle escape sequences
        if (buf[0] == '\x1b') {
            if (buf[1] == '[') {
                if (buf[2] >= '0' and buf[1] <= '9') {
                    if (buf[3] == '~') return Key.fromEscChar(buf[2]);
                } else return Key.fromEscChar(buf[2]);
            } else if (buf[1] == 'O') {
                return switch (buf[2]) {
                    'H' => Key.home,
                    'F' => Key.end,
                    else => esc,
                };
            }
        }

        const unicode = std.unicode;
        const c = switch (len) {
            1 => @as(u21, buf[0]),
            2 => unicode.utf8Decode2(buf[0..len]),
            3 => unicode.utf8Decode3(buf[0..len]),
            4 => unicode.utf8Decode4(buf[0..len]),
            else => unreachable,
        };

        break Key.fromChar(try c);
    } else unreachable;
}

/// Handles input when the editor's state is 'select'
fn onSelect(self: *Editor, key: Key) !void {
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
        Key.fromChar(term.toCtrlKey('q')) => try quit(),
        Key.fromChar(term.toCtrlKey('s')) => try self.save(),
        Key.fromChar('/') => try self.find(),
        Key.fromChar('i') => self.state = .insert,
        Key.fromChar(':') => {
            const cmd = try self.status_bar.prompt(self.gpa, null);
            defer cmd.deinit(self.gpa);

            if (cmd == .canceled) return;

            try self.buffer().get(self.text_y).appendSlice(self.gpa, self.text_x, cmd.string);
        },
        else => {},
    }
}

/// Handles the input when the editor's state is 'insert'
fn onInsert(self: *Editor, key: Key) Error!void {
    switch (key) {
        // enter
        Key.fromChar('\r') => {
            const buf = self.buffer();
            if (self.text_x == 0)
                try buf.insert(u8, self.text_y, "")
            else {
                const row = buf.get(self.text_y);
                try buf.insert(u21, self.text_y + 1, row.raw.items[self.text_x..row.len()]);
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
                try buf.delete(self.text_y);
                self.text_y -= 1;
            }
        },
        // <esc> key
        Key.fromChar(27) => self.state = .select,
        // anything else
        else => {
            const buf = self.buffer();

            if (self.text_y == buf.len()) {
                try buf.insert(u8, self.text_y, "");
            }

            const row = buf.get(self.text_y);

            try row.insert(self.gpa, self.text_x, @intCast(u21, key.int()));

            self.text_x += 1;
        },
    }
}

/// quit empties the terminal window and quits the editor
fn quit() Error!void {
    try term.sequence("2J");
    try term.sequence("H");
    try term.flush();

    should_quit.store(true, .SeqCst);
}

/// Saves the current Buffer to a file
fn save(self: *Editor) !void {
    return while (true) {
        self.buffer().save() catch |err| switch (err) {
            error.UnknownPath => {
                self.status_bar.showMessage("Path to write the file to:");
                defer self.status_bar.hideMessage();

                const result = try self.status_bar.prompt(self.gpa, null);
                defer result.deinit(self.gpa);

                if (result == .canceled) return;

                var string = std.ArrayList(u8).init(self.gpa);
                errdefer string.deinit();

                for (result.string) |cp| {
                    var buf: [4]u8 = undefined;
                    const cp_len = std.unicode.utf8Encode(cp, &buf) catch unreachable;
                    try string.writer().writeAll(buf[0..cp_len]);
                }

                self.buffer().file_path = string.toOwnedSlice();
                continue;
            },
            else => return err,
        };
        return;
    } else unreachable;
}

/// Searches for matches in the current buffer
fn find(self: *Editor) !void {
    const old_x = self.text_x;
    const old_y = self.text_y;
    const old_offset = self.row_offset;

    const on_input = struct {
        var editor: *Editor = undefined;

        var hl_row: ?*TextBuffer.TextRow = null;
        var x: u32 = 0;
        var y: u32 = 0;

        fn wrapper(input: []const u21, key: Key) void {
            if (Key.fromChar(27) == key and hl_row != null) {
                // reset its highlighting when <esc> is pressed
                hl_row.?.update(editor.gpa) catch {};
            } else if (input.len == 0 and hl_row != null) {
                // user backspaced all input, so clear highlighting
                hl_row.?.update(editor.gpa) catch {};
                editor.text_y = y;
                editor.text_x = x;
            } else for (editor.buffer().text.items) |*row, i| {
                // search through text
                if (std.mem.indexOf(u21, row.renderable, input)) |index| {
                    if (hl_row != null and hl_row != row) {
                        hl_row.?.update(editor.gpa) catch {};
                    }

                    editor.text_y = @intCast(u32, i);
                    editor.text_x = row.fromRenderIdx(index + input.len);

                    // in case user used a backspace, this will reset the previous highlighting
                    row.update(editor.gpa) catch {};

                    for (row.renderable[index .. index + input.len]) |_, idx|
                        row.highlights[index + idx] = .red;

                    hl_row = row;
                    break;
                }
            }
        }
    };
    on_input.editor = self;
    on_input.x = old_x;
    on_input.y = old_y;

    // Ask user for search query and free its resources
    const search_string = try self.status_bar.prompt(self.gpa, on_input.wrapper);
    defer search_string.deinit(self.gpa);

    if (search_string == .canceled) {
        self.text_x = old_x;
        self.text_y = old_y;
    }
}

/// Clears the screen and sets the cursor at the top
/// as well as write tildes (~) on each row
pub fn update(self: *Editor, cursor_state: enum { ignore, update }) !void {
    try self.scroll();
    try term.cursor.hide();
    try term.sequence("H");

    try self.render();
    try self.status_bar.render();

    if (cursor_state == .update) {
        const y = self.text_y - self.row_offset;
        const x = self.view_x - self.col_offset;
        try term.cursor.set(y + 1, x + 1);
    }

    try term.cursor.show();
    try term.flush();
}

/// Draws the contents of the buffer in the terminal
fn render(self: *Editor) !void {
    const nr_len = try self.lineNumberLength();

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

            try renderLineNumber(offset + 1, nr_len);
            // seperator
            try term.write(" ");

            const len = blk: {
                if (line.renderLen() - self.col_offset < 0) break :blk 0;
                var line_len = line.renderLen() - self.col_offset;

                if (line_len > self.width) line_len = self.width;
                break :blk line_len;
            };

            for (line.renderable[self.col_offset..len]) |c, index| {
                var cp: [4]u8 = undefined;
                const cp_len = try std.unicode.utf8Encode(c, &cp);

                try term.colored(line.color(index), cp[0..cp_len]);
            }

            // back to regular colours
            try term.sequence("39m");
        }

        try term.sequence("K");
        try term.write("\r\n");
    }
}

/// Determines the amount of slots required to render all line numbers
fn lineNumberLength(self: *Editor) !usize {
    const len = self.buffer().len();

    var buf: [100]u8 = undefined;
    const fmt = try std.fmt.bufPrint(&buf, "{d}", .{len});
    return fmt.len + 1;
}

/// Renders the given line number until `len` is reached
fn renderLineNumber(idx: usize, len: usize) !void {
    var buf: [100]u8 = undefined;
    const fmt = try std.fmt.bufPrint(&buf, "{d}", .{idx});

    var i: usize = 0;
    while (i + fmt.len < len) : (i += 1) try term.write(" ");
    try term.write(fmt);
}

/// Shows the startup message if no file buffer was opened
fn startupMessage(self: Editor) Error!void {
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
fn moveCursor(self: *Editor, key: Key) void {
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
fn open(self: *Editor, file_path: []const u8) !void {
    const file = try fs.cwd().openFile(file_path, .{});
    defer file.close();

    // create a temporary buffer of 40Kb where the reader will read into
    var buf: [4096 * 10]u8 = undefined;
    var text_buffer = TextBuffer.init(self.gpa, file_path);
    errdefer text_buffer.deinit();

    while (try file.reader().readUntilDelimiterOrEof(&buf, '\n')) |line| {
        // Check if the line contains a '\r'. If true, cut it off
        const real_line = blk: {
            if (line.len == 0) break :blk &[_]u8{};

            const idx = line.len - 1;
            break :blk if (line[idx] == '\r') line[0..idx] else line;
        };

        // append the line to our text buffer
        try text_buffer.insert(u8, text_buffer.len(), real_line);
    }

    try self.buffers.append(self.gpa, text_buffer);
    self.active = @intCast(u32, self.buffers.items.len) - 1;
    self.state = .select;
}

/// Handle automatic scrolling based on cursor position
fn scroll(self: *Editor) Error!void {
    self.view_x = if (self.text_y < self.buffer().len())
        self.buffer().get(self.text_y).getIdx(self.text_x)
    else
        0;

    // get the x position based on utf 8 sequence lengths
    if (self.view_x != 0) {
        self.view_x = self.buffer().utf8Pos(self.text_y, self.text_x);
    }

    self.view_x += @intCast(u32, try self.lineNumberLength()) + 1;

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
