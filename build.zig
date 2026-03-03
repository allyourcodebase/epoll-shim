const std = @import("std");
const LinkMode = std.builtin.LinkMode;

const manifest = @import("build.zig.zon");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const os = target.result.os.tag;

    const options = .{
        .linkage = b.option(LinkMode, "linkage", "Library linkage type") orelse
            .static,
    };

    if (!os.isBSD()) return;

    const upstream = b.dependency("epoll_shim_c", .{});

    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const config_h = b.addConfigHeader(
        .{ .style = .{ .autoconf_at = upstream.path("include/sys/epoll.h") } },
        .{ .POLLRDHUP_VALUE = @as(u32, 0x2000) },
    );

    const generated = b.addWriteFiles();
    _ = generated.add("epoll_shim_export.h",
        \\#define EPOLL_SHIM_EXPORT __attribute__((visibility("default")))
        \\#define EPOLL_SHIM_NO_EXPORT __attribute__((visibility("hidden")))
        \\
    );
    _ = generated.addCopyFile(config_h.getOutputFile(), "sys/epoll.h");

    mod.addCMacro("EPOLL_SHIM_DISABLE_WRAPPER_MACROS", "");
    if (os != .freebsd) {
        mod.addCMacro("__uintptr_t", "uintptr_t");
        mod.addCMacro("COMPAT_ENABLE_KQUEUE1", "");
        mod.addCMacro("COMPAT_ENABLE_SIGOPS", "");
        if (!os.isDarwin()) mod.addCMacro("errno_t", "int");

        const preamble: []const u8 = if (os.isDarwin()) preambles.bsd ++ preambles.darwin else preambles.bsd;
        const wf = b.addWriteFiles();
        var wrapped: std.ArrayListUnmanaged([]const u8) = .empty;
        for (srcs.core) |src| {
            const name = b.fmt("w_{s}", .{std.fs.path.basename(src)});
            _ = wf.add(name, b.fmt("{s}#include \"{s}\"\n", .{ preamble, src }));
            wrapped.append(b.allocator, name) catch @panic("OOM");
        }
        mod.addCSourceFiles(.{ .root = wf.getDirectory(), .files = wrapped.items, .flags = flags });
        mod.addCSourceFiles(.{ .root = upstream.path("src"), .files = if (os.isDarwin()) srcs.compat_darwin else srcs.compat_bsd, .flags = flags });
    } else {
        mod.addCSourceFiles(.{ .root = upstream.path("src"), .files = srcs.core, .flags = flags });
    }
    if (os.isDarwin()) inline for (.{ "ITIMERSPEC", "PIPE2", "SOCKET", "SOCKETPAIR", "SEM", "PPOLL" }) |name|
        mod.addCMacro("COMPAT_ENABLE_" ++ name, "");

    inline for (.{
        generated.getDirectory(),
        upstream.path("src"),
        upstream.path("external/tree-macros/include"),
        upstream.path("external/queue-macros/include"),
        upstream.path("include"),
    }) |include| mod.addIncludePath(include);

    const lib = b.addLibrary(.{
        .name = "epoll-shim",
        .root_module = mod,
        .linkage = options.linkage,
        .version = try .parse(manifest.version),
    });
    lib.installHeader(generated.getDirectory().path(b, "sys/epoll.h"), "sys/epoll.h");
    inline for (.{ "sys/signalfd.h", "sys/eventfd.h", "sys/timerfd.h" }) |h|
        lib.installHeader(upstream.path("include/" ++ h), h);
    lib.installHeadersDirectory(upstream.path("include/epoll-shim"), "epoll-shim", .{});
    b.installArtifact(lib);
}

const flags: []const []const u8 = &.{
    "-std=gnu11",
    "-fvisibility=hidden",
};

const srcs = .{
    .core = &[_][]const u8{
        "rwlock.c",      "wrap.c",         "epoll_shim_ctx.c",
        "epoll.c",       "epollfd_ctx.c",  "kqueue_event.c",
        "signalfd.c",    "signalfd_ctx.c", "timespec_util.c",
        "eventfd.c",     "eventfd_ctx.c",  "timerfd.c",
        "timerfd_ctx.c",
    },
    .compat_bsd = &[_][]const u8{
        "compat_kqueue1.c",
        "compat_sigops.c",
    },
    .compat_darwin = &[_][]const u8{
        "compat_kqueue1.c", "compat_sigops.c",     "compat_pipe2.c",
        "compat_socket.c",  "compat_socketpair.c", "compat_itimerspec.c",
        "compat_sem.c",     "compat_ppoll.c",
    },
};

const preambles = .{
    .bsd =
    \\#include "compat_kqueue1.h"
    \\#include "compat_sigops.h"
    ,
    .darwin =
    \\#include "compat_itimerspec.h"
    \\#include "compat_pipe2.h"
    \\#include "compat_socket.h"
    \\#include "compat_socketpair.h"
    \\#include "compat_sem.h"
    \\#include "compat_ppoll.h"
    ,
};
