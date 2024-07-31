const std = @import("std");

fn exists(b: *std.Build, path: []const u8) bool {
    const abs_path = b.path(path).getPath(b);
    std.fs.accessAbsolute(
        abs_path,
        .{ .mode = .read_only },
    ) catch return false;
    return true;
}

const flags = [_][]const u8{
    "-fno-sanitize=undefined",
};

const Highlights = struct { name: []const u8, path: std.Build.LazyPath };

const highlight_lang_map = std.StaticStringMap([]const u8).initComptime(
    &.{
        .{ "julia", "extra/julia-highlights.scm" },
        .{ "bash", "extra/bash-highlights.scm" },
    },
);

fn build_language(
    b: *std.Build,
    static: bool,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    lang: []const u8,
) !struct {
    hl: ?Highlights = null,
    lib: *std.Build.Step.Compile,
} {
    var arena = std.heap.ArenaAllocator.init(b.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const depname = try std.fmt.allocPrint(alloc, "tree-sitter-{s}", .{lang});
    const dep = b.dependency(depname, .{ .target = target, .optimize = optimize });

    const srcdir = "src";
    const querydir = "queries";

    const query_file_lazy_path = if (highlight_lang_map.get(lang)) |path|
        b.path(path)
    else
        dep.path(try std.fs.path.join(alloc, &.{ querydir, "highlights.scm" }));
    const save_query_file = try std.fmt.allocPrint(
        alloc,
        "{s}-highlights.scm",
        .{depname},
    );

    const parser = try std.fs.path.join(alloc, &.{ srcdir, "parser.c" });
    const scanner = try std.fs.path.join(alloc, &.{ srcdir, "scanner.c" });
    const scanner_cc = try std.fs.path.join(alloc, &.{ srcdir, "scanner.cc" });

    const lib = if (static)
        b.addStaticLibrary(.{
            .name = depname,
            .target = target,
            .optimize = optimize,
        })
    else
        b.addSharedLibrary(.{
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

    if (exists(dep.builder, scanner)) {
        lib.addCSourceFiles(.{
            .root = dep.path("."),
            .files = &.{scanner},
            .flags = &flags,
        });
    }
    if (exists(dep.builder, scanner_cc)) {
        lib.addCSourceFiles(.{
            .root = dep.path("."),
            .files = &.{scanner_cc},
            .flags = &flags,
        });
    }

    if (static) {
        return .{
            .hl = .{ .name = lang, .path = query_file_lazy_path },
            .lib = lib,
        };
    } else {
        const install_file = b.addInstallFile(
            query_file_lazy_path,
            save_query_file,
        );
        install_file.dir = .lib;
        lib.step.dependOn(&install_file.step);
        b.installArtifact(lib);
    }

    return .{ .lib = lib };
}

pub const LanguageExtension = enum {
    bash,
    c,
    julia,
    zig,
};

pub const ExtensionType = enum { shared, dynamic, static };

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const all_opt = b.option(
        bool,
        "ext-all",
        "Build all language extensions.",
    ) orelse false;
    const ext_only = b.option(
        bool,
        "ext-only",
        "Only build the extension(s), and nothing else.",
    ) orelse false;
    const ext_dir = b.option(
        []const u8,
        "ext-directory",
        "The directory to install the language extensions into.",
    ) orelse b.lib_dir;
    const ext_how = b.option(
        ExtensionType,
        "ext-type",
        "How to build the extension type? Defaults to 'dynamic'.",
    ) orelse .dynamic;

    const options = b.addOptions();
    const sym_avail = ext_how != .dynamic;

    var ext_libs = std.ArrayList(*std.Build.Step.Compile).init(b.allocator);
    defer ext_libs.deinit();

    var highlights = std.ArrayList(Highlights).init(b.allocator);
    defer highlights.deinit();

    if (all_opt) {
        b.lib_dir = ext_dir;
        inline for (@typeInfo(LanguageExtension).Enum.fields) |f| {
            const name = f.name;
            const l = try build_language(
                b,
                ext_how == .static,
                target,
                optimize,
                name,
            );

            try ext_libs.append(l.lib);
            if (l.hl) |hl| try highlights.append(hl);
            options.addOption(bool, name, sym_avail);
        }
    } else {
        inline for (@typeInfo(LanguageExtension).Enum.fields) |f| {
            const name = f.name;
            const opt = b.option(
                bool,
                "ext-" ++ name,
                "Build language extension for " ++ name,
            ) orelse false;
            if (opt) {
                b.lib_dir = ext_dir;
                const l = try build_language(
                    b,
                    ext_how == .static,
                    target,
                    optimize,
                    name,
                );

                try ext_libs.append(l.lib);
                if (l.hl) |hl| try highlights.append(hl);
            }
            options.addOption(bool, name, opt and sym_avail);
        }
    }

    if (ext_only) {
        if (ext_how == .shared) {
            const lib = b.addSharedLibrary(.{
                .name = "lang-ext",
                .link_libc = true,
                .target = target,
                .optimize = optimize,
            });
            for (ext_libs.items) |l| {
                lib.linkLibrary(l);
            }
            b.installArtifact(lib);
        }
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
        "shared-treez",
        .{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        },
    );
    mod.addOptions("options", options);
    mod.addImport("treez", treez);
    mod.linkLibrary(tree_sitter_dep.artifact("tree-sitter"));
    mod.link_libc = true;
    if (ext_how != .dynamic) {
        for (ext_libs.items) |l| {
            mod.linkLibrary(l);
        }

        for (highlights.items) |hl| {
            const temp_name = try std.fmt.allocPrint(
                b.allocator,
                "@highlights-{s}",
                .{hl.name},
            );
            mod.addAnonymousImport(temp_name, .{ .root_source_file = hl.path });
        }
    }
}
