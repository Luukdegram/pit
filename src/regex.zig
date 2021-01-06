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
    return pattern == '.' or pattern == text;
}

/// Returns true when the given `text` codepoint slice matches the pattern given in `pattern`
fn match(pattern: []const u21, text: []const u21) bool {
    if (pattern.len == 0) return true;
    if (pattern[0] == '$' and text.len == 0) return true;
    if (pattern.len > 1) switch (pattern[1]) {
        '?' => return matchQuestion(pattern, text),
        '*' => return matchStar(pattern, text),
        else => {},
    };

    if (text.len == 0) return false;
    if (pattern[0] == '(') return matchGroup(pattern, text);
    return matchOne(pattern[0], text[0]) and match(pattern[1..], text[1..]);
}

/// Checks for every element in `text` to determine if it matches `pattern`
pub fn search(self: *Regex, text: []const u21) bool {
    if (text.len == 0) return true;
    if (self.pattern.len > 1 and self.pattern[0] == '^') return match(self.pattern[1..], text);

    return for (text) |_, i| {
        if (match(self.pattern, text[i..])) break true;
    } else false;
}

/// Checks if the given `text` codepoint slice matches with the '?' regex pattern
fn matchQuestion(pattern: []const u21, text: []const u21) bool {
    return ((text.len != 0 and matchOne(pattern[0], text[0])) and match(pattern[2..], text[1..])) or
        match(pattern[2..], text);
}

/// Checks if the the given `text` codepoint slice matches with the '*' regex pattern
fn matchStar(pattern: []const u21, text: []const u21) bool {
    return ((text.len != 0 and matchOne(pattern[0], text[0])) and match(pattern, text[1..])) or
        match(pattern[2..], text);
}

fn matchGroup(pattern: []const u21, text: []const u21) bool {
    const group_end = std.mem.indexOfScalar(u21, pattern, ')') orelse return false;
    const group_pattern = pattern[1..group_end];

    if (pattern.len > group_end + 1 and pattern[group_end + 1] == '?') {
        const remainder = pattern[group_end + 2 ..];
        return (match(group_pattern, text[0..group_pattern.len]) and match(remainder, text[group_pattern.len..])) or
            match(remainder, text);
    } else if (pattern.len > group_end + 1 and pattern[group_end + 1] == '*') {
        const remainder = pattern[group_end + 2 ..];
        return (match(group_pattern, text[0..group_pattern.len]) and match(pattern, text[group_pattern.len..])) or
            match(remainder, text);
    } else {
        const remainder = pattern[group_end + 1 ..];
        return (match(group_pattern, text[0..group_pattern.len]) and match(remainder, text[group_pattern.len..]));
    }
}

fn testRegex(pattern: []const u8, text: []const u8) !bool {
    const alloc = std.testing.allocator;

    var regex = try init(alloc, pattern);
    defer regex.deinit(alloc);

    var string = std.ArrayList(u21).init(alloc);
    defer string.deinit();

    var it = (try std.unicode.Utf8View.init(text)).iterator();
    while (it.nextCodepoint()) |cp| try string.append(cp);

    return regex.search(string.items);
}

test "Regex tests" {
    const cases = .{
        // simplest
        .{ "abc", "abc", true },
        // . character
        .{ "a.c", "abc", true },
        // ? chacter
        .{ "ab?c", "ac", true },
        .{ "a?b?c?", "abc", true },
        .{ "a?b?c?", "", true },
        .{ "a?", "c", true },
        .{ "a?", "a", true },
        // * character
        .{ "a*", "", true },
        .{ "a*", "aaa", true },
        .{ "a*b", "aaaaab", true },
        .{ "a*b", "aaaaa", false },

        // grouping
        .{ "(the)", "the", true },
        .{ "I like (the) movie", "I like the movie", true },
        // ?
        .{ "I like (the)? movie", "I like  movie", true },
        .{ "I like (the)? movie", "I like the movie", true },
        .{ "I like (the)? movie", "I like my movie", false },
        // *
        .{ "I like (the)* movie", "I like the movie", true },
        .{ "I like (the)* movie", "I like  movie", true },
        .{ "I like (the)*e movie", "I like the movie", false },
        // multiple groups
        .{ "I like (the)? (movie)* from (yesterday)*", "I like the movie from yesterday", true },
        .{ "I like (the)? (movie)* from (yesterday)*", "I like  moviemoviemovie from yesterday", true },
    };

    inline for (cases) |case| {
        std.testing.expectEqual(case[2], try testRegex(case[0], case[1]));
    }
}
