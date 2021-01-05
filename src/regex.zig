const std = @import("std");

const Regex = @This();

/// The regex pattern in codepoints
pattern: []const u21,

/// Allocates a codepoint slice from the given pattern which can then be matched against
pub fn init(gpa: *std.mem.Allocator, pattern: []const u8) !Regex {
    var unicode_string = std.ArrayList(u21).init(gpa);
    errdefer unicode_string.deinit();

    var it = (try std.unicode.Utf8View.init(pattern)).iterator();
    while (it.nextCodepoint()) |cp| try unicode_string.append(cp);

    return Regex{ .pattern = unicode_string.toOwnedSlice() };
}

/// Frees the `Regex` resources and sets itself to `undefined`
pub fn deinit(self: *Regex, gpa: *std.mem.Allocator) void {
    gpa.free(self.pattern);
    self.* = undefined;
}

/// Returns true when the given input `text` matches the regex pattern
/// belonging to the current `Regex` object
pub fn matches(self: Regex, text: []const u21) bool {
    return match(self.pattern, text);
}

/// Matches a single codepoint
fn matchOne(pattern: u21, text: u21) bool {
    if (pattern == '.') return true;

    return pattern == text;
}

/// Returns true when the given `text` codepoint slice matches the pattern given in `pattern`
fn match(pattern: []const u21, text: []const u21) bool {
    if (pattern.len == 0) return true;
    if (text.len == 0) return true;
    if (pattern[0] == '$' and text.len == 0) return true;
    if (pattern.len > 1) switch (pattern[1]) {
        '?' => return matchQuestion(pattern, text),
        '*' => return matchStar(pattern, text),
        else => {},
    };
    if (pattern.len > 1 and pattern[1] == '?') return matchQuestion(pattern, text);

    return matchOne(pattern[0], text[0]) and match(pattern[1..], text[1..]);
}

/// Checks for every element in `text` to determine if it matches `pattern`
fn search(pattern: []const u21, text: []const u21) bool {
    if (pattern[0] == '^') return match(pattern[1..], text);

    return for (text) |_, i| {
        if (!match(pattern, text[i..])) break false;
    } else true;
}

/// Checks if the given `text` codepoint slice matches with the '?' regex pattern
fn matchQuestion(pattern: []const u21, text: []const u21) bool {
    if (pattern.len < 3) return text.len == 0 or text[0] == pattern[0];
    if (matchOne(pattern[0], text[0]) and match(pattern[2..], text[1..]))
        return true;

    return match(pattern[2..], text);
}

/// Checks if the the given `text` codepoint slice matches with the '*' regex pattern
fn matchStar(pattern: []const u21, text: []const u21) bool {
    if (matchOne(pattern[0], text[0]) and match(pattern, text[1..]))
        return true;

    return match(pattern[2..], text);
}

fn testRegex(pattern: []const u8, text: []const u8) !bool {
    const alloc = std.testing.allocator;

    var regex = try init(alloc, pattern);
    defer regex.deinit(alloc);

    var string = std.ArrayList(u21).init(alloc);
    defer string.deinit();

    var it = (try std.unicode.Utf8View.init(text)).iterator();
    while (it.nextCodepoint()) |cp| try string.append(cp);

    return regex.matches(string.items);
}

test "Regex tests" {
    const cases = .{
        // simplest
        .{ "abc", "abc", true },
        // ? chacter
        .{ "ab?c", "ac", true },
        .{ "a?b?c?", "abc", true },
        .{ "a?b?c?", "", true },
        .{ "a?", "c", false },
        .{ "a?", "a", true },
    };

    inline for (cases) |case| {
        std.testing.expectEqual(case[2], try testRegex(case[0], case[1]));
    }
}
