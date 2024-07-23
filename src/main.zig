const std = @import("std");
const treez = @import("treez");

const LanguageFn = *const fn () callconv(.C) ?*const treez.Language;

const LanguageSpec = struct {
    allocator: std.mem.Allocator,
    dylib: std.DynLib,
    lang: *const treez.Language,
    highlights: []const u8,

    pub fn deinit(self: *LanguageSpec) void {
        self.allocator.free(self.highlights);
        self.dylib.close();
    }
};

fn load_language(allocator: std.mem.Allocator, language: []const u8) !LanguageSpec {
    const lib_path = try std.fmt.allocPrint(
        allocator,
        "zig-out/lib/libtree-sitter-{s}.so",
        .{language},
    );
    defer allocator.free(lib_path);
    const hl_path = try std.fmt.allocPrint(
        allocator,
        "zig-out/lib/tree-sitter-{s}-highlights.scm",
        .{language},
    );
    defer allocator.free(hl_path);
    const func_name = try std.fmt.allocPrintZ(
        allocator,
        "tree_sitter_{s}",
        .{language},
    );
    defer allocator.free(func_name);

    var lib = try std.DynLib.open(lib_path);
    errdefer lib.close();

    const scm = try std.fs.cwd().readFileAlloc(allocator, hl_path, try std.math.powi(usize, 2, 32));
    errdefer allocator.free(scm);

    return .{
        .allocator = allocator,
        .dylib = lib,
        .lang = (lib.lookup(LanguageFn, func_name) orelse unreachable)().?,
        .highlights = scm,
    };
}

fn CallBack(comptime T: type) type {
    return fn (
        ctx: T,
        sel: treez.Range,
        scope: []const u8,
        id: u32,
        capture_idx: usize,
    ) anyerror!void;
}

const SyntaxHighlighter = struct {
    allocator: std.mem.Allocator,
    lang_spec: LanguageSpec,
    parser: *treez.Parser,
    query: *treez.Query,
    tree: ?*treez.Tree = null,

    fn parse(self: *SyntaxHighlighter, content: []const u8) !void {
        if (self.tree) |tree| tree.destroy();
        self.tree = try self.parser.parseString(null, content);
    }

    pub fn init(
        allocator: std.mem.Allocator,
        content: []const u8,
        language: []const u8,
    ) !SyntaxHighlighter {
        const lang_spec = try load_language(allocator, language);
        var self: SyntaxHighlighter = .{
            .allocator = allocator,
            .lang_spec = lang_spec,
            .parser = try treez.Parser.create(),
            .query = try treez.Query.create(lang_spec.lang, lang_spec.highlights),
        };
        errdefer self.deinit();
        try self.parser.setLanguage(lang_spec.lang);
        try self.parse(content);
        return self;
    }

    pub fn deinit(self: *SyntaxHighlighter) void {
        if (self.tree) |t| t.destroy();
        self.query.destroy();
        self.parser.destroy();
        self.lang_spec.deinit();
    }

    pub fn walk(self: *const SyntaxHighlighter, ctx: anytype, comptime cb: CallBack(@TypeOf(ctx))) !void {
        const cursor = try treez.Query.Cursor.create();
        defer cursor.destroy();
        const tree = if (self.tree) |p| p else return;
        cursor.execute(self.query, tree.getRootNode());
        while (cursor.nextMatch()) |match| {
            var idx: usize = 0;
            for (match.captures()) |capture| {
                try cb(ctx, capture.node.getRange(), self.query.getCaptureNameForId(capture.id), capture.id, idx);
                idx += 1;
            }
        }
    }
};

const Ctx = struct {
    content: []const u8,
    end_byte: usize = 0,

    fn call_back(
        self: *Ctx,
        range: treez.Range,
        scope: []const u8,
        id: u32,
        idx: usize,
    ) !void {
        _ = id;
        if (idx > 0) return;
        if (range.start_byte >= self.end_byte) {
            const slice = self.content[range.start_byte..range.end_byte];
            std.debug.print("> scope: {s: <30}:slice: '{s}'\n", .{
                scope,
                slice,
            });
            self.end_byte = range.start_byte + 1;
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try std.io.getStdErr().writeAll("Missing filepath!\n");
        return std.process.exit(1);
    }

    const content = try std.fs.cwd().readFileAlloc(
        allocator,
        args[1],
        10_000,
    );
    defer allocator.free(content);

    var parser = try SyntaxHighlighter.init(allocator, content, "zig");
    defer parser.deinit();

    var ctx: Ctx = .{
        .content = content,
    };
    try parser.walk(&ctx, Ctx.call_back);
}
