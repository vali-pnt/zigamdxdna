pub fn main() !void {
    const driver = try Driver.init("/dev/accel/accel0");
    defer driver.deinit();
    const version = try driver.queryAieVersion();
    std.debug.print("{}\n", .{version});
}

const Driver = struct {
    fd: std.posix.fd_t,

    const Self = @This();

    pub fn init(path: []const u8) !Self {
        const fd = try std.posix.open(path, .{ .ACCMODE = .RDWR, .NONBLOCK = true }, 0);
        return .{ .fd = fd };
    }

    pub fn deinit(self: Self) void {
        std.posix.close(self.fd);
    }

    pub fn queryAieVersion(self: Self) !amdxdna.GetInfo.QueryAieVersion {
        const version: amdxdna.GetInfo.QueryAieVersion = undefined;
        var get_info = amdxdna.GetInfo{
            .param = .query_aie_version,
            .buffer = @intFromPtr(&version),
            .buffer_size = @sizeOf(amdxdna.GetInfo.QueryAieVersion),
        };
        const r = std.os.linux.ioctl(self.fd, amdxdna.get_info_ioctl, @intFromPtr(&get_info));
        if (r != 0) return error.Fail;
        return version;
    }
};

const amdxdna = struct {
    pub const QosInfo = extern struct {
        gops: u32,
        fps: u32,
        dma_bandwidth: u32,
        latency: u32,
        frame_exec_time: u32,
        priority: u32,
    };

    pub const CreateHwctx = extern struct {
        ext: u64 = 0,
        ext_flags: u64 = 0,
        qos_p: u64,
        umq_bo: u32,
        log_buf_bo: u32,
        max_opc: u32,
        num_tiles: u32,
        mem_size: u32,
        umq_doorbell: u32 = undefined,
        handle: u32 = undefined,
        syncobj_handle: u32 = undefined,
    };

    pub const DestroyHwctx = extern struct {
        handle: u32,
        pad: u32 = 0,
    };

    pub const ConfigHwctx = extern struct {
        handle: u32,
        param_type: Param,
        param_val: u64,
        param_val_size: u32,
        pad: u32 = 0,

        pub const Param = enum(u32) {
            config_cu = 0,
            assign_dbg_buf = 1,
            remove_dbg_buf = 2,
        };
    };

    pub const CreateBo = extern struct {
        flags: u64 = 0,
        vaddr: u64 = 0,
        size: u64,
        type: Type,
        handle: u32 = undefined,

        pub const Type = enum(u32) {
            invalid = 0,
            shmem = 1,
            dev_heap = 2,
            dev = 3,
            cmd = 4,
        };
    };

    pub const GetBoInfo = extern struct {
        ext: u64 = 0,
        ext_flags: u64 = 0,
        handle: u32,
        pad: u32 = 0,
        map_offset: u64 = undefined,
        vaddr: u64 = undefined,
        xdna_vaddr: u64 = undefined,
    };

    pub const SyncBo = extern struct {
        handle: u32,
        direction: Direction,
        offset: u64,
        size: u64,

        pub const Direction = enum(u32) {
            to_device = 0,
            from_device = 1,
        };
    };

    pub const ExecCmd = extern struct {
        ext: u64 = 0,
        ext_flags: u64 = 0,
        hwctx: u32,
        type: Type,
        cmd_handles: u64,
        args: u64,
        cmd_count: u32,
        arg_count: u32,
        seq: u64 = undefined,

        pub const Type = enum(u32) {
            submit_exec_buf = 0,
            submit_dependency = 1,
            submit_signal = 2,
        };
    };

    pub const GetInfo = extern struct {
        param: Param,
        buffer_size: u32,
        buffer: u64,

        pub const Param = enum(u32) {
            query_aie_status = 0,
            query_aie_metadata = 1,
            query_aie_version = 2,
            query_clock_metadata = 3,
            query_sensors = 4,
            query_hw_contexts = 5,
            query_firmware_version = 8,
            get_power_mode = 9,
        };

        pub const QueryAieVersion = extern struct {
            major: u32,
            minor: u32,
        };
    };

    pub const create_hwctx_ioctl = drm.iowr(drm.command_base + 0x0, CreateHwctx);
    pub const destroy_hwctx_ioctl = drm.iowr(drm.command_base + 0x1, DestroyHwctx);
    pub const config_hwctx_ioctl = drm.iowr(drm.command_base + 0x2, ConfigHwctx);
    pub const create_bo_ioctl = drm.iowr(drm.command_base + 0x3, CreateBo);
    pub const get_bo_info_ioctl = drm.iowr(drm.command_base + 0x4, GetBoInfo);
    pub const sync_bo_ioctl = drm.iowr(drm.command_base + 0x5, SyncBo);
    pub const exec_cmd_ioctl = drm.iowr(drm.command_base + 0x6, ExecCmd);
    pub const get_info_ioctl = drm.iowr(drm.command_base + 0x7, ExecCmd);
};

const drm = struct {
    pub const ioctl_base = 'd';
    pub const command_base = 0x40;

    pub fn iowr(nr: u8, comptime T: type) u32 {
        return std.os.linux.IOCTL.IOWR(ioctl_base, nr, T);
    }
};

const std = @import("std");
