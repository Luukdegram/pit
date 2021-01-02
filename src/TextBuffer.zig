const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const Color = @import("term.zig").Color;

const TextBuffer = @This();

/// Helper struct to manage the buffer
/// on a per-line basis
pub const TextRow = struct {
    /// Raw text buffer that is being edited
    raw: std.ArrayListUnmanaged(u21),
    /// The text that will be rendered
    renderable: []u21,
    /// Determines if the `TextRow` has been modified
    is_dirty: bool = false,
    /// Rendarable text's colors per index
    highlights: []Color,

    /// Creates a new TextRow instance
    /// User must manage `input`'s memory
    pub fn init(gpa: *Allocator, input: []const u8) !TextRow {
        var list = std.ArrayList(u21).init(gpa);
        var it = (try std.unicode.Utf8View.init(input)).iterator();
        while (it.nextCodepoint()) |cp| try list.append(cp);

        return TextRow{
            .raw = list.toUnmanaged(),
            .renderable = try gpa.dupe(u21, list.items),
            .highlights = &[_]Color{},
        };
    }

    /// Releases all memory of the `TextRow`
    pub fn deinit(self: *TextRow, gpa: *Allocator) void {
        self.raw.deinit(gpa);
        gpa.free(self.renderable);
        gpa.free(self.highlights);
        self.* = undefined;
    }

    /// Updates the renderable text with the raw text
    pub fn update(self: *TextRow, gpa: *Allocator) error{OutOfMemory}!void {
        var tabs: u32 = 0;

        for (self.raw.items) |raw| {
            if (raw == '\t')
                tabs += 1;
        }

        // each tab is 4 spaces
        self.renderable = try gpa.realloc(self.renderable, self.len() + (tabs * 3) + 1);
        // set to zeroes
        std.mem.set(u21, self.renderable, 0);

        // self.renderable = try gpa.realloc(self.renderable, self.len());
        const space = std.unicode.utf8Decode(" ") catch unreachable;

        var i: usize = 0;
        for (self.raw.items) |c| {
            if (c == '\t') {
                self.renderable[i] = ' ';
                i += 1;
                while (i % 4 != 0) : (i += 1) self.renderable[i] = ' ';
            } else {
                self.renderable[i] = c;
                i += 1;
            }
        }

        try self.highlight(gpa);
    }

    /// Sets the highlighting pieces of the renderable text
    fn highlight(self: *TextRow, gpa: *Allocator) error{OutOfMemory}!void {
        if (self.highlights.len != self.renderable.len)
            self.highlights = try gpa.realloc(self.highlights, self.renderable.len);
        std.mem.set(Color, self.highlights, .default);

        for (self.renderable) |c, i| {
            self.highlights[i] = switch (charKind(c)) {
                .digit => .blue,
                .special => .magenta,
                .char => .default,
            };
        }
    }

    /// Returns the character kind for a given code point. Used for highlighting
    fn charKind(c: u21) enum { char, digit, special } {
        return switch (c) {
            '0'...'9' => .digit,
            '{', '}', '(', ')', '-', '+', '/', '"', '\'', '&', '%', '^', ' ', '~', ',', '.', '<', '>', '[', ']', '=' => .special,
            else => .char,
        };
    }

    /// Returns the `Color` of the character at the given index `idx`
    pub fn color(self: TextRow, idx: usize) Color {
        std.debug.assert(self.highlights.len > 0);
        return self.highlights[idx];
    }

    /// Returns the length of the raw text
    pub fn len(self: TextRow) u32 {
        return @intCast(u32, self.raw.items.len);
    }

    /// Returns the length of the renderable text
    pub fn renderLen(self: TextRow) u32 {
        var i: u32 = 0;
        for (self.renderable) |cp| {
            const cp_len = std.unicode.utf8CodepointSequenceLength(cp) catch unreachable;
            i += cp_len;
        }
        // return i;
        return @intCast(u32, self.renderable.len);
    }

    /// Given the index of a character inside the `raw` text,
    /// returns the corresponding index from the `renderable` text.
    pub fn getIdx(self: TextRow, idx: usize) u32 {
        var offset: u32 = 0;
        var i: usize = 0;
        while (i < idx) : (i += 1) {
            if (self.raw.items[i] == '\t')
                offset += 3 - (offset % 4);
            offset += 1;
        }
        return offset;
    }

    /// Returns the index of the renderable character from a given raw index `idx`
    pub fn fromRenderIdx(self: TextRow, idx: usize) u32 {
        var render_x: u32 = 0;
        var i: u32 = 0;
        while (i < self.len()) : (i += 1) {
            if (self.raw.items[i] == '\t')
                render_x += 3 - (render_x % 4);
            render_x += 1;

            if (render_x > idx) return i;
        }
        return i;
    }

    /// Inserts a character at index `idx` and updates the renderable text
    pub fn insert(self: *TextRow, gpa: *Allocator, idx: u32, c: u21) error{OutOfMemory}!void {
        self.is_dirty = true;
        if (idx > self.len())
            try self.raw.append(gpa, c)
        else
            try self.raw.insert(gpa, idx, c);

        try self.update(gpa);
    }

    /// Replaces the character at index `idx` with `c`
    pub fn replace(self: *TextRow, gpa: *Allocator, idx: u32, c: u21) error{OutOfMemory}!void {
        if (idx > self.len()) return;
        self.is_dirty = true;

        self.raw.items[idx] = c;

        try self.update(gpa);
    }

    /// Removes the character found at index `idx`
    pub fn remove(self: *TextRow, gpa: *Allocator, idx: u32) error{OutOfMemory}!void {
        if (idx > self.len()) return;
        self.is_dirty = true;

        _ = self.raw.orderedRemove(idx);

        try self.update(gpa);
    }

    /// Appends a slice at index `idx`
    pub fn appendSlice(self: *TextRow, gpa: *Allocator, idx: u32, slice: []const u21) error{OutOfMemory}!void {
        try self.raw.insertSlice(gpa, idx, slice);

        try self.update(gpa);
    }

    /// Resizes the raw text buffer to the given size
    pub fn resize(self: *TextRow, gpa: *Allocator, n: u32) error{OutOfMemory}!void {
        try self.raw.resize(gpa, n);
        try self.update(gpa);
    }
};

/// Mutable list of `TextRow`
text: std.ArrayListUnmanaged(TextRow),
/// File name that the buffer corresponds to
file_path: ?[]const u8 = null,

/// Creates a new instance of `TextBuffer`
pub fn init(file_name: ?[]const u8) TextBuffer {
    return .{
        .text = std.ArrayListUnmanaged(TextRow){},
        .file_path = file_name,
    };
}

/// Frees all memory of the buffer
pub fn deinit(self: *TextBuffer, gpa: *Allocator) void {
    for (self.text.items) |*row| row.deinit(gpa);
    self.text.deinit(gpa);
    self.* = undefined;
}

/// Appends a new `TextRow` onto the buffer from the given `input` text
pub fn insert(self: *TextBuffer, comptime T: type, gpa: *Allocator, idx: u32, input: []const T) !void {
    var row = if (T == u8)
        try TextRow.init(gpa, input)
    else if (T == u21)
        TextRow{
            .raw = std.ArrayList(T).fromOwnedSlice(gpa, try gpa.dupe(T, input)).toUnmanaged(),
            .renderable = &[_]T{},
            .highlights = &[_]Color{},
        }
    else
        @compileError("Unsupported type. T must be u8 or u21");

    if (input.len > 0) try row.update(gpa);
    try self.text.insert(gpa, idx, row);
}

/// Returns the `TextRow` at index `idx`
/// Asserts `text` has elements
pub fn get(self: *TextBuffer, idx: usize) *TextRow {
    std.debug.assert(self.text.items.len > 0);

    return &self.text.items[idx];
}

/// Returns the amount of rows the buffer contains
pub fn len(self: TextBuffer) u32 {
    return @intCast(u32, self.text.items.len);
}

/// Returns true when any of the buffer's rows are dirty
pub fn isDirty(self: TextBuffer) bool {
    return for (self.text.items) |row| {
        if (row.is_dirty) break true;
    } else false;
}

/// Removes the row at index `idx`
pub fn delete(self: *TextBuffer, gpa: *Allocator, idx: u32) error{OutOfMemory}!void {
    if (idx == self.len()) return;
    var row = self.text.orderedRemove(idx);
    const new_row = self.get(idx - 1);
    try new_row.appendSlice(gpa, new_row.len(), row.raw.items);
    row.deinit(gpa);
}

/// Returns the utf8 encoded character's position of the character found at row `row_idx` and index `col_idx`
/// This expects `col_idx` to be that of the rendered x's position.
/// `n` is the difference between an initial position and this position
pub fn utf8Pos(self: *TextBuffer, row_idx: u32, col_idx: u32) u32 {
    const row = self.get(row_idx);
    const idx = row.getIdx(col_idx);

    var pos: u32 = 0;
    for (row.renderable[0..idx]) |c| {
        var pc = c;
        var width: u32 = 0;
        while (pc > 0) {
            width += 1;
            pc >>= 8;
        }

        pos += width;
    }
    return pos;
}

/// Errorset for saving a file
pub const SaveError = error{
    UnknownPath,
    Utf8CannotEncodeSurrogateHalf,
    CodepointTooLarge,
} || fs.File.OpenError || fs.File.WriteError;

/// Saves the contents of the buffer to the file located at `file_path`
pub fn save(self: TextBuffer) SaveError!void {
    const path = self.file_path orelse return error.UnknownPath;

    const file = try fs.cwd().createFile(path, .{});
    defer file.close();

    const writer = file.writer();
    for (self.text.items) |*row| {
        // try writer.writeAll(row.raw.items);
        for (row.raw.items) |cp, i| {
            var buf: [4]u8 = undefined;
            const cp_len = try std.unicode.utf8Encode(cp, &buf);
            try writer.writeAll(buf[0..cp_len]);
        }
        try writer.writeAll("\n");

        row.is_dirty = false;
    }
}
