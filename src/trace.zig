pub fn main() !u8 {
    if (std.os.argv.len < 2) {
        std.debug.print("Usage: {s} <program> [program args]\n", .{std.os.argv[0]});
        return 1;
    }

    const child_pid = try posix.fork();
    if (child_pid == 0) {
        try posix.ptrace(linux.PTRACE.TRACEME, 0, 0, 0);
        try posix.kill(linux.getpid(), linux.SIG.STOP);
        var buf = [1]u8{0} ** 512;
        const child_path = try std.fs.cwd().realpathZ(std.os.argv[1], &buf);
        const child_args = try std.heap.page_allocator.allocSentinel(?[*:0]const u8, std.os.argv.len - 1, null);
        defer std.heap.page_allocator.free(child_args);
        @memcpy(child_args, std.os.argv[1..]);
        return @intCast(linux.execve(@ptrCast(child_path), child_args, &.{}));
    } else {
        var trace = try Trace.init(child_pid);
        try trace.run();
    }

    return 0;
}

const Trace = struct {
    child: posix.pid_t,
    xdna_fd: ?usize = null,

    pub fn init(child: posix.pid_t) !Trace {
        _ = posix.waitpid(child, 0);
        try posix.ptrace(linux.PTRACE.SETOPTIONS, child, 0, PTRACE_O_TRACESYSGOOD);
        return .{ .child = child };
    }

    pub fn run(self: *Trace) !void {
        while (true) {
            if (self.waitSyscall()) break;
            const before = try self.getRegs();

            const nr: linux.syscalls.X64 = @enumFromInt(before.regs.orig_rax);
            const arg0 = before.regs.rdi;
            const arg1 = before.regs.rsi;
            const arg2 = before.regs.rdx;
            const arg3 = before.regs.r10;
            const arg4 = before.regs.r8;
            const arg5 = before.regs.r9;
            switch (nr) {
                .openat => {
                    if (self.waitSyscall()) break;
                    const after = try self.getRegs();
                    const ret = after.regs.rax;
                    const signed: isize = @bitCast(ret);
                    const path = try self.readStr(arg1);
                    defer std.heap.page_allocator.free(path);
                    if (signed >= 0 and std.mem.eql(u8, path, "/dev/accel/accel0")) {
                        std.debug.print("-- openat(\"{s}\") = {}\n", .{ path, signed });
                        if (self.xdna_fd) |_| return error.TwoXdnaOpenedAtOnce;
                        self.xdna_fd = ret;
                    }
                },
                .open => {
                    if (self.waitSyscall()) break;
                    const after = try self.getRegs();
                    const ret = after.regs.rax;
                    const signed: isize = @bitCast(ret);
                    const path = try self.readStr(arg0);
                    defer std.heap.page_allocator.free(path);
                    if (signed >= 0 and std.mem.eql(u8, path, "/dev/accel/accel0")) {
                        std.debug.print("-- open(\"{s}\") = {}\n", .{ path, signed });
                        if (self.xdna_fd) |_| return error.TwoXdnaOpenedAtOnce;
                        self.xdna_fd = ret;
                    }
                },
                .close => {
                    if (self.xdna_fd == arg0) {
                        self.xdna_fd = null;
                        std.debug.print("-- close({})\n", .{arg0});
                    }
                    if (self.waitSyscall()) break;
                },
                .ioctl => {
                    if (self.xdna_fd == arg0) try self.printIoctlBefore(@truncate(arg1), arg2);
                    if (self.waitSyscall()) break;
                    const after = try self.getRegs();
                    if (self.xdna_fd == arg0) try self.printIoctlAfter(@truncate(arg1), arg2, after.regs.rax);
                },
                .mmap => {
                    if (self.waitSyscall()) break;
                    const after = try self.getRegs();
                    const ret = after.regs.rax;
                    if (self.xdna_fd == arg4) {
                        std.debug.print("mmap(addr: 0x{x}, length: {}, prot: ", .{ arg0, arg1 });
                        const prot = arg2;
                        if (prot | linux.PROT.EXEC != 0) std.debug.print("EXEC | ", .{});
                        if (prot | linux.PROT.READ != 0) std.debug.print("READ | ", .{});
                        if (prot | linux.PROT.WRITE != 0) std.debug.print("WRITE", .{});
                        const flags: linux.MAP = @bitCast(@as(u32, @truncate(arg3)));
                        std.debug.print(", flags: {s} | ", .{@tagName(flags.TYPE)});
                        if (flags.ANONYMOUS) std.debug.print("ANONYMOUS | ", .{});
                        if (flags.FIXED) std.debug.print("FIXED | ", .{});
                        if (flags.LOCKED) std.debug.print("LOCKED", .{});
                        std.debug.print(", offset: 0x{x}) = 0x{x}\n", .{ arg5, ret });
                    }
                },
                else => {
                    if (self.waitSyscall()) break;
                    //const after = try self.getRegs();
                    //const ret = after.regs.rax;
                    //std.debug.print("{s}() = {}\n", .{ @tagName(nr), ret });
                },
            }
        }
    }

    fn waitSyscall(self: Trace) bool {
        while (true) {
            posix.ptrace(linux.PTRACE.SYSCALL, self.child, 0, 0) catch continue;
            const status = posix.waitpid(self.child, 0).status;
            if (posix.W.IFSTOPPED(status) and posix.W.STOPSIG(status) & 0x80 != 0) return false;
            if (posix.W.IFEXITED(status)) return true;
        }
    }

    fn getRegs(self: Trace) !c.user {
        var user: c.user = undefined;
        try posix.ptrace(linux.PTRACE.GETREGS, self.child, 0, @intFromPtr(&user));
        return user;
    }

    fn readStr(self: Trace, addr: usize) ![]u8 {
        const gpa = std.heap.page_allocator;
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(gpa);

        var offset: usize = 0;
        while (true) {
            var word: usize = undefined;
            try posix.ptrace(linux.PTRACE.PEEKDATA, self.child, addr + offset, @intFromPtr(&word));
            try buf.appendSlice(gpa, std.mem.asBytes(&word));
            if (std.mem.indexOfScalar(u8, buf.items[offset..], 0)) |i| {
                buf.shrinkRetainingCapacity(offset + i);
                break;
            }
            offset += @sizeOf(usize);
        }

        return buf.toOwnedSlice(gpa);
    }

    fn readNBytes(self: Trace, addr: usize, n: comptime_int) ![n]u8 {
        const wordsize = @sizeOf(usize);
        var bytes: [n]u8 = undefined;
        var offset: usize = 0;

        while (offset < n) {
            var word: usize = undefined;
            try posix.ptrace(linux.PTRACE.PEEKDATA, self.child, addr + offset, @intFromPtr(&word));
            if (n - offset < wordsize) {
                @memcpy(bytes[offset..], std.mem.asBytes(&word)[0..(n - offset)]);
            } else @memcpy(bytes[offset..(offset + wordsize)], std.mem.asBytes(&word));
            offset += @sizeOf(usize);
        }

        return bytes;
    }

    fn readStruct(self: Trace, addr: usize, T: type) !T {
        const bytes = try self.readNBytes(addr, @sizeOf(T));
        return std.mem.bytesToValue(T, &bytes);
    }

    fn printIoctlBefore(self: Trace, cmd: u32, arg: usize) !void {
        switch (cmd) {
            xdna.create_hwctx_ioctl => {
                const s = try self.readStruct(arg, xdna.CreateHwctx);
                const qos = try self.readStruct(s.qos_p, xdna.QosInfo);
                std.debug.print("CreateHwctx:\n", .{});
                std.debug.print("  qos:\n", .{});
                std.debug.print("    gops: {}\n", .{qos.gops});
                std.debug.print("    fps: {}\n", .{qos.fps});
                std.debug.print("    dma_bandwidth: {}\n", .{qos.dma_bandwidth});
                std.debug.print("    latency: {}\n", .{qos.latency});
                std.debug.print("    frame_exec_time: {}\n", .{qos.frame_exec_time});
                std.debug.print("    priority: {}\n", .{qos.priority});
                std.debug.print("  umq_bo: {}\n", .{s.umq_bo});
                std.debug.print("  log_buf_bo: {}\n", .{s.log_buf_bo});
                std.debug.print("  max_opc: {}\n", .{s.max_opc});
                std.debug.print("  num_tiles: {}\n", .{s.num_tiles});
                std.debug.print("  mem_size: {}\n", .{s.mem_size});
            },
            xdna.destroy_hwctx_ioctl => {
                const s = try self.readStruct(arg, xdna.DestroyHwctx);
                std.debug.print("DestroyHwctx:\n", .{});
                std.debug.print("  handle: {}\n", .{s.handle});
            },
            xdna.config_hwctx_ioctl => {
                std.debug.print("ConfigHwctx\n", .{});
            },
            xdna.create_bo_ioctl => {
                const s = try self.readStruct(arg, xdna.CreateBo);
                std.debug.print("CreateBo:\n", .{});
                std.debug.print("  size: {}\n", .{s.size});
                std.debug.print("  type: {s}\n", .{@tagName(s.type)});
            },
            xdna.get_bo_info_ioctl => {
                const s = try self.readStruct(arg, xdna.GetBoInfo);
                std.debug.print("GetBoInfo:\n", .{});
                std.debug.print("  handle: {}\n", .{s.handle});
            },
            xdna.sync_bo_ioctl => {
                std.debug.print("SyncBo\n", .{});
            },
            xdna.exec_cmd_ioctl => {
                std.debug.print("ExecCmd\n", .{});
            },
            xdna.get_info_ioctl => {
                std.debug.print("GetInfo:\n", .{});
            },
            xdna.set_state_ioctl => {
                std.debug.print("SetState\n", .{});
            },
            drm.gem_close_ioctl => {
                const s = try self.readStruct(arg, drm.GemClose);
                std.debug.print("GemClose:\n", .{});
                std.debug.print("  handle: {}\n", .{s.handle});
            },
            else => {
                const req: linux.IOCTL.Request = @bitCast(cmd);
                std.debug.print("Unknown(type: {} nr: {}, size: {})\n", .{ req.io_type, req.nr, req.size });
            },
        }
    }

    fn printIoctlAfter(self: Trace, cmd: u32, arg: usize, ret: usize) !void {
        switch (cmd) {
            xdna.create_hwctx_ioctl => {
                const s = try self.readStruct(arg, xdna.CreateHwctx);
                std.debug.print("  => umq_doorbell: {}\n", .{s.umq_doorbell});
                std.debug.print("  => handle: {}\n", .{s.handle});
                std.debug.print("  => syncobj_handle: {}\n", .{s.syncobj_handle});
                std.debug.print("  ret: {}\n", .{ret});
            },
            xdna.create_bo_ioctl => {
                const s = try self.readStruct(arg, xdna.CreateBo);
                std.debug.print("  => handle: {}\n", .{s.handle});
                std.debug.print("  ret: {}\n", .{ret});
            },
            xdna.get_bo_info_ioctl => {
                const s = try self.readStruct(arg, xdna.GetBoInfo);
                std.debug.print("  => map_offset: 0x{x}\n", .{s.map_offset});
                std.debug.print("  => vaddr: 0x{x}\n", .{s.vaddr});
                std.debug.print("  => xdna_vaddr: 0x{x}\n", .{s.xdna_vaddr});
                std.debug.print("  ret: {}\n", .{ret});
            },
            xdna.get_info_ioctl => {
                const s = try self.readStruct(arg, xdna.GetInfo);
                switch (s.param) {
                    .query_aie_metadata => {
                        const q = try self.readStruct(s.buffer, xdna.GetInfo.QueryAieMetadata);
                        std.debug.print("  QueryAieMetadata: {}\n", .{q});
                    },
                    else => {},
                }
                std.debug.print("  ret: {}\n", .{ret});
            },
            else => {},
        }
    }
};

const PTRACE_O_TRACESYSGOOD = 0x1;

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const c = @cImport(@cInclude("sys/user.h"));
const drm = @import("drm.zig");
const xdna = @import("xdna.zig");
