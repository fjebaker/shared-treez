const std = @import("std");

fn exists(b: *std.Build, path: []const u8) bool {
    std.fs.cwd().access(
        b.pathFromRoot(path),
        .{ .mode = .read_only },
    ) catch return false;
    return true;
}

const flags = [_][]const u8{
    "-fno-sanitize=undefined",
};

fn build_language(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    lang: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(b.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const depname = try std.fmt.allocPrint(alloc, "tree-sitter-{s}", .{lang});
    const dep = b.dependency(depname, .{ .target = target, .optimize = optimize });

    const srcdir = "src";
    const querydir = "queries";

    const query_file = try std.fs.path.join(alloc, &.{ querydir, "highlights.scm" });
    const save_query_file = try std.fmt.allocPrint(alloc, "{s}-highlights.scm", .{depname});

    const parser = try std.fs.path.join(alloc, &.{ srcdir, "parser.c" });
    const scanner = try std.fs.path.join(alloc, &.{ srcdir, "scanner.c" });
    const scanner_cc = try std.fs.path.join(alloc, &.{ srcdir, "scanner.cc" });

    const lib = b.addSharedLibrary(.{
        .name = depname,
        .target = target,
        .optimize = optimize,
    });

    lib.addCSourceFiles(.{
        .root = dep.path("."),
        .files = &.{parser},
        .flags = &flags,
    });
    lib.linkLibC();

    if (exists(b, scanner)) {
        lib.addCSourceFiles(.{
            .root = dep.path("."),
            .files = &.{scanner},
            .flags = &flags,
        });
    }

    if (exists(b, scanner_cc)) {
        lib.addCSourceFiles(.{
            .root = dep.path("."),
            .files = &.{scanner_cc},
            .flags = &flags,
        });
    }

    const install_file = b.addInstallFile(dep.path(query_file), save_query_file);
    install_file.dir = .lib;

    const install_lib = b.addInstallArtifact(lib, .{});
    install_file.step.dependOn(&install_lib.step);
    b.getInstallStep().dependOn(&install_file.step);
}

const LangName = enum {
    zig,
    c,
    pub fn toString(s: LangName) []const u8 {
        return @tagName(s);
    }
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lang_opt = b.option(LangName, "lang", "Build a language extension.");
    const all_opt = b.option(bool, "all", "Build all language extensions.");

    if (lang_opt) |lang| {
        try build_language(b, target, optimize, lang.toString());
    }

    if (all_opt) |all| {
        if (all) {
            for (std.meta.fieldNames(LangName)) |name| {
                try build_language(b, target, optimize, name);
            }
        }
    }

    if (lang_opt != null or all_opt != null) {
        return;
    }

    const treez_dep = b.dependency(
        "treez",
        .{ .target = target, .optimize = optimize },
    );
    const treez = treez_dep.module("treez");
    const tree_sitter_dep = treez_dep.builder.dependency(
        "tree-sitter",
        .{ .target = target, .optimize = optimize },
    );

    const mod = b.addModule(
        "treez-shared",
        .{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        },
    );
    mod.addImport("treez", treez);
    mod.linkLibrary(tree_sitter_dep.artifact("tree-sitter"));
    mod.link_libc = true;
}
