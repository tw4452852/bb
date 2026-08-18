const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const bpf_path = b.option([]const []const u8, "bpf", "Path to BPF program");
    const user_path = b.option([]const []const u8, "user", "Path to user-space program");

    var skeleton_header: ?std.Build.LazyPath = null;
    if (bpf_path) |p| {
        skeleton_header = try build_bpf(b, target, p);
    }

    if (user_path) |p| {
        build_user(b, target, optimize, p, skeleton_header);
    }
}

fn build_bpf(b: *std.Build, target: std.Build.ResolvedTarget, src_paths: []const []const u8) error{OutOfMemory}!std.Build.LazyPath {
    const vmlinux_dep = b.dependency("vmlinux", .{});
    const libbpf_dep = b.dependency("libbpf", .{});
    const endian = switch (target.result.cpu.arch.endian()) {
        .big => "eb",
        .little => "el",
    };
    const family = target.result.cpu.arch.family();
    const arch = switch (family) {
        .arm, .aarch64, .x86, .powerpc, .s390x => @tagName(family),
        else => std.debug.panic("Arch family {} is not supported!", .{family}),
    };

    // Compile every object
    const obj_paths = try b.allocator.alloc(std.Build.LazyPath, src_paths.len);
    defer b.allocator.free(obj_paths);
    for (src_paths, 0..) |src_path, i| {
        const name = std.fs.path.stem(src_path);

        const run_zig_cc = b.addRunFile(std.Build.LazyPath.zig_exe);
        run_zig_cc.addArgs(&.{ "cc", "-g", "-O2" });
        run_zig_cc.addArg("-fno-unwind-tables"); // Otherwise .eh_frame section will be generated which causes object linker failure
        run_zig_cc.addArgs(&.{ "-target", "bpf" ++ endian ++ "-freestanding" });
        run_zig_cc.addArgs(&.{b.fmt("-D__TARGET_ARCH_{s}", .{arch})});
        run_zig_cc.addDirectoryArg2(libbpf_dep.artifact("bpf").getEmittedIncludeTree(), .{ .prefix = "-I" });
        run_zig_cc.addDirectoryArg2(vmlinux_dep.path(b.fmt("include/{s}", .{arch})), .{ .prefix = "-I" });
        run_zig_cc.addArg("-c");
        run_zig_cc.addFileArg(b.graph.cwdRelativePath(src_path));
        const raw_obj_path = run_zig_cc.addOutputFileArg2(b.fmt("{s}.o", .{name}), .{ .prefix = "-o" });
        run_zig_cc.expectExitCode(0);

        obj_paths[i] = raw_obj_path;

        b.getInstallStep().dependOn(&b.addInstallFileWithDir(raw_obj_path, .{ .custom = "obj" }, b.fmt("{s}.o", .{name})).step);
    }

    const bpftool = build_bpftool(b);

    // Link objects
    const output_bpf_program_name = if (src_paths.len == 1)
        std.fs.path.stem(src_paths[0])
    else
        "bpf_prog";
    const run_bpftool_obj = b.addRunArtifact(bpftool);
    run_bpftool_obj.addArgs(&.{ "gen", "object" });
    const final_obj_path = run_bpftool_obj.addOutputFileArg2(b.fmt("{s}.o", .{output_bpf_program_name}), .{});
    for (obj_paths) |obj_path| {
        run_bpftool_obj.addFileArg(obj_path);
    }
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(final_obj_path, .{ .custom = "obj" }, b.fmt("{s}.o", .{output_bpf_program_name})).step);

    // Generate skeleton header
    const run_bpftool_skel = b.addRunArtifact(bpftool);
    run_bpftool_skel.addArgs(&.{ "gen", "skeleton" });
    run_bpftool_skel.addFileArg(final_obj_path);
    const skeleton_basename = std.fs.path.stem(output_bpf_program_name); // strip one more time
    const stdout = run_bpftool_skel.captureStdOut(.{ .basename = b.fmt("{s}.skel.h", .{skeleton_basename}) });
    b.getInstallStep().dependOn(&b.addInstallHeaderFile(stdout, b.fmt("{s}.skel.h", .{skeleton_basename})).step);

    return stdout;
}

fn build_bpftool(b: *std.Build) *std.Build.Step.Compile {
    const target_host = std.Build.resolveTargetQuery(b, .{});
    const optimize: std.builtin.OptimizeMode = .Debug;
    const src_dep = b.dependency("bpftool", .{});
    const libbpf_dep = b.dependency("libbpf", .{ .target = target_host, .optimize = optimize });
    const zlib_dep = b.dependency("zlib", .{ .target = target_host, .optimize = optimize });
    const libelf_dep = b.dependency("libelf", .{ .target = target_host, .optimize = optimize });

    const root_module = b.createModule(.{
        .target = target_host,
        .optimize = optimize,
        .link_libc = true,
    });
    root_module.addCSourceFiles(.{
        .root = src_dep.path("src"),
        .files = &.{
            "main.c",
            "common.c",
            "json_writer.c",
            "gen.c",
            "btf.c",
        },
        .flags = &.{
            "-DBPFTOOL_WITHOUT_CRYPTO", // Not support signing yet, as it depends on libcrypto
        },
    });
    root_module.linkLibrary(libbpf_dep.artifact("bpf"));
    root_module.linkLibrary(libelf_dep.artifact("elf"));
    root_module.linkLibrary(zlib_dep.artifact("z"));
    root_module.addIncludePath(src_dep.path("include"));

    const bin = b.addExecutable(.{ .name = "bpftool", .root_module = root_module });
    b.installArtifact(bin);
    return bin;
}

fn build_user(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, src_paths: []const []const u8, skeleton_header: ?std.Build.LazyPath) void {
    const libbpf_dep = b.dependency("libbpf", .{ .target = target, .optimize = optimize });
    const root_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    root_module.linkLibrary(libbpf_dep.artifact("bpf"));
    if (skeleton_header) |p| {
        root_module.addIncludePath(p.dirname());
    }

    for (src_paths) |src_path| {
        root_module.addCSourceFile(.{ .file = b.graph.cwdRelativePath(src_path) });
    }

    const output_user_program_name = if (src_paths.len == 1)
        std.fs.path.stem(src_paths[0])
    else
        "user_prog";

    const bin = b.addExecutable(.{ .name = output_user_program_name, .root_module = root_module });
    b.installArtifact(bin);
}
