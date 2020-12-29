const std = @import("std");
const Allocator = std.mem.Allocator;

const TextBuffer = @This();

/// Helper struct to manage the buffer
/// on a per-line basis
pub const TextRow = struct {
    raw: std.ArrayListUnmanaged(u8),
    renderable: []u8,

    /// Creates a new TextRow instance
    /// User must manage `input`'s memory
    pub fn init(gpa: *Allocator, input: []const u8) error{OutOfMemory}!TextRow {
        return TextRow{
            .raw = std.ArrayList(u8).fromOwnedSlice(gpa, try gpa.dupe(u8, input)).toUnmanaged(),
            .renderable = try gpa.dupe(u8, input),
        };
    }

    /// Releases all memory of the `TextRow`
    pub fn deinit(self: *TextRow, gpa: *Allocator) void {
        self.raw.deinit(gpa);
        gpa.free(self.renderable);
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
    pub fn getIdx(self: TextRow, idx: u32) u32 {
        var offset: u32 = 0;
        var i: usize = 0;
        while (i < idx) : (i += 1) {
            if (self.raw.items[i] == '\t')
                offset += 3 - (offset % 4);
            offset += 1;
        }
        return offset;
    }

    /// Inserts a character at index `idx` and updates the renderable text
    pub fn insert(self: *TextRow, gpa: *Allocator, idx: u32, c: u8) error{OutOfMemory}!void {
        if (idx > self.len())
            try self.raw.append(gpa, c)
        else
            try self.raw.insert(gpa, idx, c);

        try self.update(gpa);
    }

    /// Replaces the character at index `idx` with `c`
    pub fn replace(self: *TextRow, idx: u32, c: u8) void {
        if (idx > self.len()) return;

        self.raw.items[idx] = c;
    }

    /// Removes the character found at index `idx`
    pub fn remove(self: *TextRow, idx: u32) void {
        if (idx > self.len()) return;

        _ = self.raw.orderedRemove(idx);
    }
};

/// Mutable list of `TextRow`
text: std.ArrayListUnmanaged(TextRow),
file_name: []const u8,

/// Creates a new instance of `TextBuffer`
pub fn init(file_name: []const u8) TextBuffer {
    return .{
        .text = std.ArrayListUnmanaged(TextRow){},
        .file_name = file_name,
    };
}

/// Frees all memory of the buffer
pub fn deinit(self: *TextBuffer, gpa: *Allocator) void {
    for (self.text.items) |*row| row.deinit(gpa);
    self.text.deinit(gpa);
    self.* = undefined;
}

/// Appends a new `TextRow` onto the buffer from the given `input` text
pub fn append(self: *TextBuffer, gpa: *Allocator, input: []const u8) error{OutOfMemory}!void {
    var row = try TextRow.init(gpa, input);
    if (input.len > 0) try row.update(gpa);

    try self.text.append(gpa, row);
}

/// Returns the `TextRow` at index `idx`
/// Asserts `idx` is not out of bounds
pub fn get(self: *TextBuffer, idx: usize) *TextRow {
    std.debug.assert(idx < self.text.items.len);

    return &self.text.items[idx];
}

/// Returns the amount of rows the buffer contains
pub fn len(self: TextBuffer) u32 {
    return @intCast(u32, self.text.items.len);
}
