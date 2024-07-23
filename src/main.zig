const std = @import("std");
const syntax = @import("syntax");

const Ctx = struct {
    content: []const u8,
    end_byte: usize = 0,

    fn call_back(
        self: *Ctx,
        range: syntax.Range,
        scope: []const u8,
        id: u32,
        idx: usize,
        _: *const syntax.Node,
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

    const parser = try syntax.create_guess_file_type(allocator, content, args[1]);
    defer parser.destroy();

    var ctx: Ctx = .{
        .content = content,
    };
    try parser.render(&ctx, Ctx.call_back, null);
}
