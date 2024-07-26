const std = @import("std");
const treez = @import("treez");
pub usingnamespace treez;

pub const LanguageExtension = struct {
    name: []const u8,
    function_symbol: ?[:0]const u8 = null,
    shared_object_name: ?[]const u8 = null,
    highlight_path: ?[]const u8 = null,
};

pub const LanguageInitFn = *const fn () callconv(.C) ?*const treez.Language;

pub const LanguageSpec = struct {
    allocator: std.mem.Allocator,
    dylib: std.DynLib,
    lang: *const treez.Language,
    highlights: []const u8,

    pub fn deinit(self: *LanguageSpec) void {
        self.allocator.free(self.highlights);
        self.dylib.close();
    }
};

pub const LangExtError = error{NoInitSymbol};

pub fn load_language_extension(
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
    const hl_name = l.highlight_path orelse try std.fmt.allocPrint(
        alloc,
        "tree-sitter-{s}-highlights.scm",
        .{l.name},
    );
    const func_symbol = l.function_symbol orelse try std.fmt.allocPrintZ(
        alloc,
        "tree_sitter_{s}",
        .{l.name},
    );

    var lib = try std.DynLib.open(try dir.realpathAlloc(alloc, lib_name));
    errdefer lib.close();

    const scm = try dir.readFileAlloc(
        allocator,
        hl_name,
        try std.math.powi(usize, 2, 32),
    );
    errdefer allocator.free(scm);

    const func = lib.lookup(LanguageInitFn, func_symbol) orelse
        return LangExtError.NoInitSymbol;

    return .{
        .allocator = allocator,
        .dylib = lib,
        .lang = func().?,
        .highlights = scm,
    };
}
