const std = @import("std");
const os = std.os;
const io = std.io;

const BufferedWriter = io.BufferedWriter(4096, TermWriter);
const Term = struct {
    in: os.fd_t,
    out: os.fd_t,
    termios: os.termios,
    out_buffer: BufferedWriter,
};

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

var term_instance: ?Term = null;

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

    term_instance = Term{
        .in = fd,
        .termios = original_termios,
        .out = std.io.getStdOut().handle,
        .out_buffer = io.bufferedWriter(TermWriter{ .fd = std.io.getStdOut().handle }),
    };
}

/// Resets the tty to the original values
pub fn deinit() void {
    const term = get();
    os.tcsetattr(term.in, .FLUSH, term.termios) catch {};
}

/// Returns `true` if the given `char` is a control character
pub fn isCntrl(char: u8) bool {
    return char <= 0x1f or char == 0x7f;
}

/// Given a character such as 'q' will return the control variant
/// i.e. ctrl+q
pub fn toCtrlKey(char: u8) u8 {
    return char & 0x01f;
}

/// Reads the input from stdin. Returns error.EndOfStream on timeout
pub fn read() !u8 {
    return std.io.getStdIn().reader().readByte();
}

/// Write `input` to std out's buffer. Call `flush()` to flush it out
pub fn write(input: []const u8) os.WriteError!void {
    try get().out_buffer.writer().writeAll(input);
}

/// Writes an escape sequence to stdout
pub fn sequence(comptime input: []const u8) os.WriteError!void {
    try write(escape ++ input);
}

/// Dimensions of the tty, going from left top corner to right bottom corner.
pub const Dimensions = struct { width: u16, height: u16 };
pub fn size() error{Unexpected}!Dimensions {
    var tmp = std.mem.zeroes(os.winsize);
    const err_no = os.system.ioctl(get().in, os.TIOCGWINSZ, @ptrToInt(&tmp));
    return switch (os.errno(err_no)) {
        0 => Dimensions{ .width = tmp.ws_col, .height = tmp.ws_row },
        else => os.unexpectedErrno(err_no),
    };
}

/// Cursor position's row and column
const Position = struct { row: u16, col: u16 };

/// Returns the current position of the cursor
pub fn cursorPos() !Position {
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

/// Flushes the buffer to stdout
pub fn flush() os.WriteError!void {
    try get().out_buffer.flush();
}

/// Hides the cursor
pub fn hideCursor() os.WriteError!void {
    try sequence("?25l");
}

/// Shows the cursor
pub fn showCursor() os.WriteError!void {
    try sequence("?25h");
}

/// Sets the cursor at position `row`,`col`.
pub fn setCursor(row: u16, col: u16) os.WriteError!void {
    try get().out_buffer.writer().print(escape ++ "{d};{d}H", .{ row + 1, col + 1 });
}

pub const escape = "\x1b[";
