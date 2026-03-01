# epoll-shim zig

[epoll-shim](https://github.com/jiixyj/epoll-shim), packaged for the Zig build system.

Provides epoll/eventfd/signalfd/timerfd APIs on BSD/macOS systems using kqueue.

## Using

```zig
const dep = b.dependency("epoll-shim", .{ .target = target, .optimize = optimize });
exe.root_module.linkLibrary(dep.artifact("epoll-shim"));
```
