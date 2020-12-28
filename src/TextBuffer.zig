const std = @import("std");
const Allocator = std.mem.Allocator;

const TextBuffer = @This();

/// Helper struct to manage the buffer
/// on a per-line basis
pub const TextRow = struct {
    raw: []u8,
    renderable: []u8,

    /// Creates a new TextRow instance
    /// User must manage `input`'s memory
    pub fn init(input: []u8, gpa: *Allocator) error{OutOfMemory}!TextRow {
        return TextRow{ .raw = input, .renderable = try gpa.dupe(u8, input) };
    }

    /// Updates the renderable text with the raw text
    pub fn update(self: *TextRow, gpa: *Allocator) error{OutOfMemory}!void {
        var tabs: u32 = 0;

        for (self.raw) |raw| tabs += if (raw == '\t') @as(u32, 1) else 0;
        gpa.free(self.renderable);

        // each tab is 4 spaces
        self.renderable = try gpa.alloc(u8, self.raw.len + tabs * 3 + 1);

        var i: usize = 0;
        while (i < self.raw.len) {
            const c = self.raw[i];

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

    /// Returns the length of the renderable text
    pub fn len(self: TextRow) usize {
        return self.renderable.len;
    }
};

text: std.ArrayListUnmanaged(TextRow),

/// Creates a new instance of `TextBuffer`
pub fn init() TextBuffer {
    return .{ .text = std.ArrayListUnmanaged(TextRow){} };
}

/// Frees all memory of the buffer
pub fn deinit(self: *TextBuffer, gpa: *Allocator) void {
    for (self.text.items) |row| {
        gpa.free(row.raw);
        gpa.free(row.renderable);
    }
    self.text.deinit(gpa);
    self.* = undefined;
}

/// Appends a singular `TextRow` to the buffer
pub fn append(self: *TextBuffer, gpa: *Allocator, row: TextRow) error{OutOfMemory}!void {
    try self.text.append(gpa, row);
}

/// Returns the `TextRow` at index `idx`
/// Asserts `idx` is not out of bounds
pub fn get(self: *TextBuffer, idx: usize) *TextRow {
    std.debug.assert(idx < self.text.items.len);

    return &self.text.items[idx];
}

/// Returns the amount of rows the buffer contains
pub fn len(self: TextBuffer) usize {
    return self.text.items.len;
}
