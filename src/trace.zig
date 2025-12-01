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
        defer trace.deinit();
        try trace.run();
    }

    return 0;
}

const BoTrace = struct {
    size: u64,
    type: xdna.CreateBo.Type,
    info: ?Driver.BoInfo = null,
};

const Trace = struct {
    child: posix.pid_t,
    xdna_fd: ?usize = null,
    bos: std.AutoHashMap(u32, BoTrace) = .init(std.heap.page_allocator),

    pub fn init(child: posix.pid_t) !Trace {
        _ = posix.waitpid(child, 0);
        try posix.ptrace(linux.PTRACE.SETOPTIONS, child, 0, PTRACE_O_TRACESYSGOOD);
        return .{ .child = child };
    }

    pub fn deinit(self: *Trace) void {
        self.bos.deinit();
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
                        self.log("openat(\"{s}\") = {}", .{ path, signed });
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
                        self.log("open(\"{s}\") = {}", .{ path, signed });
                        if (self.xdna_fd) |_| return error.TwoXdnaOpenedAtOnce;
                        self.xdna_fd = ret;
                    }
                },
                .close => {
                    if (self.xdna_fd == arg0) {
                        self.xdna_fd = null;
                        self.log("close({})", .{arg0});
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
                        const flags: linux.MAP = @bitCast(@as(u32, @truncate(arg3)));
                        self.log("mmap(addr: 0x{x}, length: {}, prot: {s}{s}{s}, flags: {s} |{s}{s}{s}, offset: 0x{x}) = 0x{x}", .{
                            arg0,
                            arg1,
                            if (arg2 | linux.PROT.EXEC != 0) "EXEC | " else "",
                            if (arg2 | linux.PROT.READ != 0) "READ | " else "",
                            if (arg2 | linux.PROT.WRITE != 0) "WRITE" else "",
                            @tagName(flags.TYPE),
                            if (flags.ANONYMOUS) " ANONYMOUS |" else "",
                            if (flags.FIXED) " FIXED |" else "",
                            if (flags.LOCKED) " LOCKED" else "",
                            arg5,
                            ret,
                        });
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

    fn readSlice(self: Trace, addr: usize, len: usize) ![]u8 {
        const gpa = std.heap.page_allocator;
        var buf = try gpa.alloc(u8, len);
        errdefer gpa.free(buf);
        var offset: usize = 0;

        while (offset < len) {
            var word: usize = undefined;
            try posix.ptrace(linux.PTRACE.PEEKDATA, self.child, addr + offset, @intFromPtr(&word));
            if (len - offset < @sizeOf(usize)) {
                @memcpy(buf[offset..], std.mem.asBytes(&word)[0..(len - offset)]);
            } else @memcpy(buf[offset..(offset + @sizeOf(usize))], std.mem.asBytes(&word));
            offset += @sizeOf(usize);
        }

        return buf;
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

    fn printIoctlBefore(self: *Trace, cmd: u32, arg: usize) !void {
        switch (cmd) {
            xdna.create_hwctx_ioctl => {
                const s = try self.readStruct(arg, xdna.CreateHwctx);
                const qos = try self.readStruct(s.qos_p, xdna.QosInfo);

                self.log("CreateHwctx:", .{});
                self.log("  qos:", .{});
                self.log("    gops: {}", .{qos.gops});
                self.log("    fps: {}", .{qos.fps});
                self.log("    dma_bandwidth: {}", .{qos.dma_bandwidth});
                self.log("    latency: {}", .{qos.latency});
                self.log("    frame_exec_time: {}", .{qos.frame_exec_time});
                self.log("    priority: {}", .{qos.priority});
                self.log("  umq_bo: {}", .{s.umq_bo});
                self.log("  log_buf_bo: {}", .{s.log_buf_bo});
                self.log("  max_opc: {}", .{s.max_opc});
                self.log("  num_tiles: {}", .{s.num_tiles});
                self.log("  mem_size: {}", .{s.mem_size});
            },
            xdna.destroy_hwctx_ioctl => {
                const s = try self.readStruct(arg, xdna.DestroyHwctx);

                self.log("DestroyHwctx:", .{});
                self.log("  handle: {}", .{s.handle});
            },
            xdna.config_hwctx_ioctl => {
                const s = try self.readStruct(arg, xdna.ConfigHwctx);
                self.log("ConfigHwctx:", .{});
                self.log("  handle: {}", .{s.handle});
                self.log("  param_type: {}", .{s.param_type});
                if (s.param_type == xdna.ConfigHwctx.Param.config_cu) {
                    const num_cus = try self.readStruct(s.param_val, u16);
                    self.log("    ConfigCu:", .{});
                    for (0..num_cus) |i| {
                        const cu_config = try self.readStruct(
                            s.param_val + 8 + @sizeOf(xdna.ConfigHwctx.CuConfig) * i,
                            xdna.ConfigHwctx.CuConfig,
                        );
                        self.log("      cu_bo: {}, cu_func: {}", .{ cu_config.cu_bo, cu_config.cu_func });
                        const bo_trace = self.bos.getPtr(cu_config.cu_bo).?;
                        const data = try self.readSlice(bo_trace.info.?.vaddr, bo_trace.size);
                        defer std.heap.page_allocator.free(data);
                        self.log("        data: {x}", .{data});
                    }
                }
            },
            xdna.create_bo_ioctl => {
                const s = try self.readStruct(arg, xdna.CreateBo);
                self.log("CreateBo:", .{});
                self.log("  size: {}", .{s.size});
                self.log("  type: {s}", .{@tagName(s.type)});
            },
            xdna.get_bo_info_ioctl => {
                const s = try self.readStruct(arg, xdna.GetBoInfo);
                self.log("GetBoInfo:", .{});
                self.log("  handle: {}", .{s.handle});
            },
            xdna.sync_bo_ioctl => {
                self.log("SyncBo", .{});
            },
            xdna.exec_cmd_ioctl => {
                self.log("ExecCmd", .{});
            },
            xdna.get_info_ioctl => {
                self.log("GetInfo", .{});
            },
            xdna.set_state_ioctl => {
                self.log("SetState", .{});
            },
            drm.gem_close_ioctl => {
                const s = try self.readStruct(arg, drm.GemClose);
                _ = self.bos.remove(s.handle);
                self.log("GemClose:", .{});
                self.log("  handle: {}", .{s.handle});
            },
            else => {
                const req: linux.IOCTL.Request = @bitCast(cmd);
                self.log("Unknown(type: {} nr: {}, size: {})", .{ req.io_type, req.nr, req.size });
            },
        }
    }

    fn printIoctlAfter(self: *Trace, cmd: u32, arg: usize, ret: usize) !void {
        switch (cmd) {
            xdna.create_hwctx_ioctl => {
                const s = try self.readStruct(arg, xdna.CreateHwctx);
                self.log("  => umq_doorbell: {}", .{s.umq_doorbell});
                self.log("  => handle: {}", .{s.handle});
                self.log("  => syncobj_handle: {}", .{s.syncobj_handle});
                self.log("  ret: {}", .{ret});
            },
            xdna.create_bo_ioctl => {
                const s = try self.readStruct(arg, xdna.CreateBo);
                try self.bos.put(s.handle, .{ .size = s.size, .type = s.type });
                self.log("  => handle: {}", .{s.handle});
                self.log("  ret: {}", .{ret});
            },
            xdna.get_bo_info_ioctl => {
                const s = try self.readStruct(arg, xdna.GetBoInfo);
                const bo_trace = self.bos.getPtr(s.handle).?;
                bo_trace.info = .{
                    .map_offset = s.map_offset,
                    .vaddr = s.vaddr,
                    .xdna_vaddr = s.xdna_vaddr,
                };
                self.log("  => map_offset: 0x{x}", .{s.map_offset});
                self.log("  => vaddr: 0x{x}", .{s.vaddr});
                self.log("  => xdna_vaddr: 0x{x}", .{s.xdna_vaddr});
                self.log("  ret: {}", .{ret});
            },
            xdna.get_info_ioctl => {
                const s = try self.readStruct(arg, xdna.GetInfo);
                switch (s.param) {
                    .query_aie_metadata => {
                        const q = try self.readStruct(s.buffer, xdna.GetInfo.QueryAieMetadata);
                        self.log("  QueryAieMetadata: {}", .{q});
                    },
                    else => {},
                }
                self.log("  ret: {}", .{ret});
            },
            else => {},
        }
    }

    fn log(_: Trace, comptime fmt: []const u8, args: anytype) void {
        std.debug.print("[xdnatrace] " ++ fmt ++ "\n", args);
    }
};

const PTRACE_O_TRACESYSGOOD = 0x1;

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const c = @cImport(@cInclude("sys/user.h"));
const drm = @import("drm.zig");
const xdna = @import("xdna.zig");
const Driver = @import("Driver.zig");
