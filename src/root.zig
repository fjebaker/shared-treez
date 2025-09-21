const std = @import("std");
const options = @import("options");

pub const treez = @import("treez");

pub const LanguageExtension = struct {
    name: []const u8,
    function_symbol: ?[:0]const u8 = null,
    shared_object_name: ?[]const u8 = null,
    highlight_path: ?[]const u8 = null,
};

pub const LanguageInitFn = *const fn () callconv(.c) ?*const treez.Language;

pub const LanguageSpec = struct {
    allocator: std.mem.Allocator,
    dylib: ?std.DynLib,
    lang: *const treez.Language,
    highlights: []const u8,

    pub fn deinit(self: *LanguageSpec) void {
        if (self.dylib) |*dl| {
            self.allocator.free(self.highlights);
            dl.close();
        }
    }
};

pub const LangExtError = error{NoInitSymbol};
pub const TreeSitterFn = fn () ?*const treez.Language;

pub fn load_language_extension(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    l: LanguageExtension,
) !LanguageSpec {
    inline for (@typeInfo(options).@"struct".decls) |f| {
        if (@field(options, f.name)) {
            const func = @extern(?*TreeSitterFn, .{ .name = "tree_sitter_" ++ f.name }).?;
            if (std.mem.eql(u8, f.name, l.name)) {
                return .{
                    .allocator = allocator,
                    .dylib = null,
                    .lang = func().?,
                    .highlights = @embedFile("@highlights-" ++ f.name),
                };
            }
        }
    }

    return try dynamic_load_language_extension(allocator, dir, l);
}

pub fn dynamic_load_language_extension(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    l: LanguageExtension,
) !LanguageSpec {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const lib_name = l.shared_object_name orelse try std.fmt.allocPrint(
        alloc,
        "libtree-sitter-{s}.so",
        .{l.name},
    );
    const func_symbol = l.function_symbol orelse try std.fmt.allocPrintSentinel(
        alloc,
        "tree_sitter_{s}",
        .{l.name},
        0,
    );

    var lib = try std.DynLib.open(try dir.realpathAlloc(alloc, lib_name));
    errdefer lib.close();

    const func = lib.lookup(LanguageInitFn, func_symbol) orelse
        return LangExtError.NoInitSymbol;

    return .{
        .allocator = allocator,
        .dylib = lib,
        .lang = func().?,
        .highlights = try load_highlights(allocator, dir, l),
    };
}

/// Caller owns the memory
fn load_highlights(allocator: std.mem.Allocator, dir: std.fs.Dir, l: LanguageExtension) ![]const u8 {
    const hl_name = l.highlight_path orelse try std.fmt.allocPrint(
        allocator,
        "tree-sitter-{s}-highlights.scm",
        .{l.name},
    );
    defer allocator.free(hl_name);
    return try dir.readFileAlloc(
        allocator,
        hl_name,
        try std.math.powi(usize, 2, 32),
    );
}
