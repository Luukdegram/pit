const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const Color = @import("term.zig").Color;

const TextBuffer = @This();

/// Helper struct to manage the buffer
/// on a per-line basis
pub const TextRow = struct {
    /// Raw text buffer that is being edited
    raw: std.ArrayListUnmanaged(u8),
    /// The text that will be rendered
    renderable: []u8,
    /// Determines if the `TextRow` has been modified
    is_dirty: bool = false,
    /// Rendarable text's colors per index
    highlights: []Color,

    /// Creates a new TextRow instance
    /// User must manage `input`'s memory
    pub fn init(gpa: *Allocator, input: []const u8) error{OutOfMemory}!TextRow {
        return TextRow{
            .raw = std.ArrayList(u8).fromOwnedSlice(gpa, try gpa.dupe(u8, input)).toUnmanaged(),
            .renderable = try gpa.dupe(u8, input),
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
        gpa.free(self.renderable);

        // each tab is 4 spaces
        self.renderable = try gpa.alloc(u8, self.len() + tabs * 3 + 1);

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
        self.highlights = try gpa.realloc(self.highlights, self.renderable.len);

        for (self.renderable) |c, i| self.highlights[i] = if (std.ascii.isDigit(c))
            .green
        else
            .default;
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
    pub fn insert(self: *TextRow, gpa: *Allocator, idx: u32, c: u8) error{OutOfMemory}!void {
        self.is_dirty = true;
        if (idx > self.len())
            try self.raw.append(gpa, c)
        else
            try self.raw.insert(gpa, idx, c);

        try self.update(gpa);
    }

    /// Replaces the character at index `idx` with `c`
    pub fn replace(self: *TextRow, gpa: *Allocator, idx: u32, c: u8) error{OutOfMemory}!void {
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
    pub fn appendSlice(self: *TextRow, gpa: *Allocator, idx: u32, slice: []const u8) error{OutOfMemory}!void {
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
pub fn insert(self: *TextBuffer, gpa: *Allocator, idx: u32, input: []const u8) error{OutOfMemory}!void {
    var row = try TextRow.init(gpa, input);
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

/// Errorset for saving a file
pub const SaveError = error{UnknownPath} || fs.File.OpenError || fs.File.WriteError;

/// Saves the contents of the buffer to the file located at `file_path`
pub fn save(self: TextBuffer) SaveError!void {
    const path = self.file_path orelse return error.UnknownPath;

    const file = try fs.cwd().createFile(path, .{});
    defer file.close();

    const writer = file.writer();
    for (self.text.items) |*row| {
        try writer.writeAll(row.raw.items);
        try writer.writeAll("\n");

        row.is_dirty = false;
    }
}
