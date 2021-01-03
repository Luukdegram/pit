const std = @import("std");
const os = std.os;
const io = std.io;

/// Alias to a buffered TermWriter
const BufferedWriter = io.BufferedWriter(4096, TermWriter);

/// Global Term struct to save our variables
const Term = struct {
    in: os.fd_t,
    out: os.fd_t,
    termios: os.termios,
    out_buffer: BufferedWriter,
};

/// Writer wrapper for our buffered writer
const TermWriter = struct {
    fd: os.fd_t,

    pub const Error = os.WriteError;

    pub fn print(self: TermWriter, comptime fmt: []const u8, args: anytype) Error!usize {
        return std.fmt.format(self, format, args);
    }

    pub fn write(self: TermWriter, bytes: []const u8) Error!usize {
        return os.write(self.fd, bytes);
    }

    pub fn writeAll(self: TermWriter, bytes: []const u8) Error!void {
        var index: usize = 0;
        while (index != bytes.len) {
            index += try os.write(self.fd, bytes[index..]);
        }
    }
};

/// 16-bit colors
pub const Color = enum(u6) {
    default = 39,
    black = 30,
    red = 31,
    green = 32,
    yellow = 33,
    blue = 34,
    magenta = 35,
    cyan = 36,
    white = 37,

    /// Returns the integer value
    pub fn val(self: Color) u6 {
        return @enumToInt(self);
    }
};

/// Global instance of our `Term`
var term_instance: ?Term = null;
/// alias to string literal of an escape sequence
pub const escape = "\x1b[";

/// Returns the Term instance
/// Asserts the instance is not null
fn get() *Term {
    std.debug.assert(term_instance != null);
    return &term_instance.?;
}

/// Initializes the tty config
pub fn init() os.TermiosSetError!void {
    const fd = std.io.getStdIn().handle;
    const original_termios = try os.tcgetattr(fd);

    var new_termios = original_termios;
    new_termios.iflag &= ~@as(os.tcflag_t, os.BRKINT | os.ICRNL | os.INPCK | os.ISTRIP | os.IXON);
    new_termios.oflag &= ~@as(os.tcflag_t, os.OPOST);
    new_termios.cflag |= @as(os.tcflag_t, os.CS8);
    new_termios.lflag &= ~@as(os.tcflag_t, os.ECHO | os.ICANON | os.IEXTEN | os.ISIG);
    new_termios.cc[6] = 0; // VMIN
    new_termios.cc[5] = 1; // VTIME

    try os.tcsetattr(fd, .FLUSH, new_termios);

    const out_fd = io.getStdOut().handle;
    term_instance = Term{
        .in = fd,
        .termios = original_termios,
        .out = out_fd,
        .out_buffer = io.bufferedWriter(TermWriter{ .fd = out_fd }),
    };
}

/// Resets the tty to the original values
pub fn deinit() void {
    const term = get();
    os.tcsetattr(term.in, .FLUSH, term.termios) catch {};
}

/// Returns `true` if the given `char` is a control character
pub fn isCntrl(char: anytype) bool {
    const T = @TypeOf(char);
    if (@typeInfo(T) != .Int) @compileError("Only integers are allowed");
    return char <= 0x1f or char == 0x7f;
}

/// Given a character such as 'q' will return the control variant
/// i.e. ctrl+q
pub fn toCtrlKey(char: u8) u8 {
    return char & 0x01f;
}

/// Reader interface for stdin
pub const Reader = io.Reader(*Term, os.ReadError, read);

/// Returns a `Reader` into stdin
pub fn reader() Reader {
    return .{ .context = get() };
}

/// Reads from stdin. Returns 0 when timeout
fn read(context: *Term, bytes: []u8) os.ReadError!usize {
    return os.read(context.in, bytes);
}

/// Write `input` to std out's buffer. Call `flush()` to flush it out
pub fn write(input: []const u8) os.WriteError!void {
    try get().out_buffer.writer().writeAll(input);
}

/// Writes a singular byte to std out's buffer
pub fn writeByte(c: u8) os.WriteError!void {
    try get().out_buffer.writer().writeByte(c);
}

/// Prints a formatted slice to the terminal's output
pub fn print(comptime fmt: []const u8, args: anytype) os.WriteError!void {
    try get().out_buffer.writer().print(fmt, args);
}

/// Writes an escape sequence to stdout
pub fn sequence(comptime input: []const u8) os.WriteError!void {
    try write(escape ++ input);
}

/// Writes the input byte/slice to stdout in the given `Color`
pub fn colored(color: Color, input: anytype) os.WriteError!void {
    const T = @TypeOf(input);
    std.debug.assert(T == u8 or T == []u8 or T == []const u8);

    try print(escape ++ "{d}m", .{color.val()});
    if (T == u8)
        try writeByte(input)
    else
        try write(input);
}

/// Dimensions of the tty, going from left top corner to right bottom corner.
pub const Dimensions = struct { width: u16, height: u16 };

/// Returns the current Dimensions of the terminal window
pub fn size() error{Unexpected}!Dimensions {
    var tmp = std.mem.zeroes(os.winsize);
    const err_no = os.system.ioctl(get().in, os.TIOCGWINSZ, @ptrToInt(&tmp));
    return switch (os.errno(err_no)) {
        0 => Dimensions{ .width = tmp.ws_col, .height = tmp.ws_row },
        else => os.unexpectedErrno(err_no),
    };
}

/// Flushes the buffer to stdout
pub fn flush() os.WriteError!void {
    try get().out_buffer.flush();
}

/// Cursor namespace
pub const cursor = struct {
    /// Cursor position's row and column
    const Position = struct { row: u16, col: u16 };

    /// Hides the cursor
    pub fn hide() os.WriteError!void {
        try sequence("?25l");
    }

    /// Shows the cursor
    pub fn show() os.WriteError!void {
        try sequence("?25h");
    }

    /// Sets the cursor at position `row`,`col`.
    pub fn set(row: u32, col: u32) os.WriteError!void {
        try get().out_buffer.writer().print(escape ++ "{d};{d}H", .{ row, col });
    }

    /// Returns the current position of the cursor
    pub fn getPos() !Position {
        var buffer: [32]u8 = undefined;
        var i: usize = 0;

        try sequence("6n");
        try flush();

        while (i < buffer.len) : (i += 1) {
            if ((try os.read(get().in, buffer[i .. i + 1])) != 1) break;
            if (buffer[i] == 'R') break;
        }

        if (buffer[0] != '\x1b' or buffer[1] != '[') return error.NoCursorFound;
        var it = std.mem.tokenize(buffer[2..i], ";");

        const row = it.next() orelse return error.NoCursorFound;
        const col = it.next() orelse return error.NoCursorFound;

        return Position{
            .row = try std.fmt.parseInt(u16, row, 0),
            .col = try std.fmt.parseInt(u16, col, 0),
        };
    }

    /// Saves the current cursor positon
    pub fn save() os.WriteError!void {
        try sequence("s");
    }

    /// Restores the cursor to the last saved position
    pub fn restore() os.WriteError!void {
        try sequence("u");
    }
};
