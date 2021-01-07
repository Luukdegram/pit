const std = @import("std");
const known_folders = @import("known_folders");
const Regex = @import("regex.zig");

/// Represents all configurable options users can set
/// to customize their editor experience
pub const Config = struct {
    line_numbers: bool = true,
    line_seperator: u8 = ' ',
    file_configs: std.StringHashMap(FileConfig),

    /// Initializes a `Config`
    pub fn init(gpa: *std.mem.Allocator) Config {
        return .{ .file_configs = std.StringHashMap(FileConfig).init(gpa) };
    }

    /// Looks for a config file in any of the 'known folders'
    /// If none found, will use Pit's default config
    pub fn fromKnownFolder(gpa: *std.mem.Allocator) !Config {
        // look for config directory. If not found, use default config
        const dir: std.fs.Dir = (try known_folders.open(gpa, .roaming_configuration, .{})) orelse return init(gpa);
        defer dir.close();

        // open Pit's folder, once again if it does not exist use defaults
        const pit_dir = dir.openDir("pit", .{}) catch |err| switch (err) {
            error.FileNotFound => return init(gpa),
            else => |e| return e,
        };
    }
};

/// Configuration based on a file
/// For example, it contains syntax highlighting information
/// for a .zig file
pub const FileConfig = struct {
    /// The file extension this configuration is triggered by
    /// i.e. 'zig'
    file_ext: []const u8,
    /// The syntax highlighting rules for this language
    highlights: []Highlighter,
};

/// Contains the regex that determines which highlighter to be used
/// as well as the type it represents
pub const Highlighter = struct {
    /// regex rule to use
    regex: Regex,
    /// highlight type it represents
    hl_type: HighlightType,
};

/// Possible syntax types
pub const HighlightType = enum {
    function,
    operator,
    string,
    number,
    typed,
    variable,
    parameter,
    keyword,
    comment,
    multi_comment_start,
    multi_comment_end,
};
