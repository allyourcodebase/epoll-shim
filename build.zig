const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const linkage = b.option(std.builtin.LinkMode, "linkage", "Library linkage type") orelse .static;

    const upstream = b.dependency("upstream", .{});
    const src = upstream.path("src");
    const os = target.result.os.tag;
    const is_freebsd = os == .freebsd;
    const is_apple = os == .macos or os == .ios or os == .tvos;

    const gen_wf = b.addWriteFiles();
    _ = gen_wf.add("epoll_shim_export.h", export_h);
    const sed = b.addSystemCommand(&.{ "sed", "s/@POLLRDHUP_VALUE@/0x2000/g" });
    sed.addFileArg(upstream.path("include/sys/epoll.h"));
    _ = gen_wf.addCopyFile(sed.captureStdOut(.{}), "sys/epoll.h");

    const flags: []const []const u8 = &(.{
        "-fvisibility=hidden", "-std=gnu11", "-DEPOLL_SHIM_DISABLE_WRAPPER_MACROS",
    } ++ .{if (!is_freebsd) "-D__uintptr_t=uintptr_t" else ""} ++
        .{if (!is_freebsd and !is_apple) "-Derrno_t=int" else ""});

    const mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    mod.addIncludePath(src);
    mod.addIncludePath(gen_wf.getDirectory());
    mod.addIncludePath(upstream.path("external/tree-macros/include"));
    mod.addIncludePath(upstream.path("external/queue-macros/include"));
    mod.addIncludePath(upstream.path("include"));

    if (!is_freebsd) {
        const compat: []const []const u8 = if (is_apple) apple_compat else bsd_compat;
        const extra: []const u8 = if (is_apple) apple_preamble else "";
        const wf = b.addWriteFiles();
        var files: std.ArrayListUnmanaged([]const u8) = .empty;
        for ([_][]const []const u8{ core_sources, compat }) |list|
            for (list) |file| {
                const name = b.fmt("w_{s}", .{std.fs.path.basename(file)});
                _ = wf.add(name, b.fmt("{s}{s}#include \"{s}\"\n", .{ compat_preamble, extra, file }));
                files.append(b.allocator, name) catch @panic("OOM");
            };
        mod.addCSourceFiles(.{ .root = wf.getDirectory(), .files = files.items, .flags = flags });
    } else {
        mod.addCSourceFiles(.{ .root = src, .files = core_sources, .flags = flags });
    }

    const lib = b.addLibrary(.{ .name = "epoll-shim", .root_module = mod, .linkage = linkage });
    lib.installHeader(gen_wf.getDirectory().path(b, "sys/epoll.h"), "sys/epoll.h");
    inline for (.{ "sys/signalfd.h", "sys/eventfd.h", "sys/timerfd.h" }) |h|
        lib.installHeader(upstream.path("include/" ++ h), h);
    lib.installHeadersDirectory(upstream.path("include/epoll-shim"), "epoll-shim", .{});
    b.installArtifact(lib);
}

const export_h =
    \\#ifndef EPOLL_SHIM_EXPORT_H
    \\#define EPOLL_SHIM_EXPORT_H
    \\#ifdef EPOLL_SHIM_STATIC_DEFINE
    \\#  define EPOLL_SHIM_EXPORT
    \\#  define EPOLL_SHIM_NO_EXPORT
    \\#else
    \\#  define EPOLL_SHIM_EXPORT __attribute__((visibility("default")))
    \\#  define EPOLL_SHIM_NO_EXPORT __attribute__((visibility("hidden")))
    \\#endif
    \\#endif
    \\
;

const compat_preamble =
    \\#define COMPAT_ENABLE_KQUEUE1
    \\#include "compat_kqueue1.h"
    \\#define COMPAT_ENABLE_SIGOPS
    \\#include "compat_sigops.h"
    \\
;

const apple_preamble =
    \\#define COMPAT_ENABLE_ITIMERSPEC
    \\#include "compat_itimerspec.h"
    \\#define COMPAT_ENABLE_PIPE2
    \\#include "compat_pipe2.h"
    \\#define COMPAT_ENABLE_SOCKET
    \\#include "compat_socket.h"
    \\#define COMPAT_ENABLE_SOCKETPAIR
    \\#include "compat_socketpair.h"
    \\#define COMPAT_ENABLE_SEM
    \\#include "compat_sem.h"
    \\#define COMPAT_ENABLE_PPOLL
    \\#include "compat_ppoll.h"
    \\
;

const core_sources: []const []const u8 = &.{
    "rwlock.c",      "wrap.c",         "epoll_shim_ctx.c",
    "epoll.c",       "epollfd_ctx.c",  "kqueue_event.c",
    "signalfd.c",    "signalfd_ctx.c", "timespec_util.c",
    "eventfd.c",     "eventfd_ctx.c",  "timerfd.c",
    "timerfd_ctx.c",
};

const bsd_compat: []const []const u8 = &.{ "compat_kqueue1.c", "compat_sigops.c" };

const apple_compat: []const []const u8 = &.{
    "compat_kqueue1.c", "compat_sigops.c",     "compat_pipe2.c",
    "compat_socket.c",  "compat_socketpair.c", "compat_itimerspec.c",
    "compat_sem.c",     "compat_ppoll.c",
};
