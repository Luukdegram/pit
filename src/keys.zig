const std = @import("std");

/// Keys mapped from utf-8 codepoints to Pit keys
pub const Key = enum(u32) {
    // from here we can insert our own keys as they're no longer codepoints
    arrow_left = 2097152,
    arrow_right,
    arrow_up,
    arrow_down,
    home,
    end,
    delete,
    insert,
    page_up,
    page_down,
    _,

    pub const UtfError = error{Utf8EncodeFailed};

    /// Checks if the `Key` equals the given character `c`
    pub fn eql(self: Key, c: u21) bool {
        return @enumToInt(self) == c;
    }

    /// Returns the codepoint value of the `Key`
    pub fn int(self: Key) u32 {
        return @enumToInt(self);
    }

    /// Returns the `Key` as a valid utf8 encoded slice
    pub fn utf8(self: Key) UtfError![]const u8 {
        std.debug.assert(self.int() <= std.math.maxInt(u21));
        var buffer: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(@intCast(u21, self.int()), &buffer) catch
            return UtfError.Utf8EncodeFailed;

        return buffer[0..len];
    }

    /// Returns true when `Key` equals the <esc> key
    pub fn isEsc(self: Key) bool {
        return @enumToInt(self) == '\x1b';
    }

    /// Returns a `Key` from a codepoint
    pub fn fromChar(cp: u21) Key {
        return @intToEnum(Key, cp);
    }

    /// Returns the corresponding `Key` from a character found after an escape sequence
    pub fn fromEscChar(c: u21) Key {
        return switch (c) {
            '1' => .home,
            '2' => .insert,
            '3' => .delete,
            '4' => .end,
            '5' => .page_up,
            '6' => .page_down,
            '7' => .home,
            '8' => .end,
            'A' => .arrow_up,
            'B' => .arrow_down,
            'C' => .arrow_right,
            'D' => .arrow_left,
            'F' => .end,
            'H' => .home,
            else => unreachable,
        };
    }
};
