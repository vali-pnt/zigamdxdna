pub fn main() !void {
    const driver = try Driver.init("/dev/accel/accel0");
    defer driver.deinit();

    const aie_metadata = try driver.queryAieMetadata();
    const aie_version = aie_metadata.version;
    std.debug.print("aie version: {}.{}\n", .{ aie_version.major, aie_version.minor });
    const fw_version = try driver.queryFirmwareVersion();
    std.debug.print("fw version: {}.{}.{} build {}\n", .{ fw_version.major, fw_version.minor, fw_version.patch, fw_version.build });
    std.debug.print("col size: {}\n", .{aie_metadata.col_size});
    std.debug.print("cols: {}, rows: {}\n", .{ aie_metadata.cols, aie_metadata.rows });
    printTileMetadata("core", aie_metadata.core);
    printTileMetadata("mem", aie_metadata.mem);
    printTileMetadata("shim", aie_metadata.shim);

    const dev_heap_size = 64 * 1024 * 1024; // 64MB
    const dev_heap_bo = try driver.createBo(.dev_heap, dev_heap_size);
    defer driver.destroyBo(dev_heap_bo);
    const dev_heap_bo_info = try driver.getBoInfo(dev_heap_bo);
    const dev_heap_bo_map = try std.posix.mmap(
        null,
        dev_heap_size,
        std.os.linux.PROT.READ | std.os.linux.PROT.WRITE,
        .{ .TYPE = .SHARED },
        driver.fd,
        dev_heap_bo_info.map_offset,
    );
    defer std.posix.munmap(dev_heap_bo_map);

    const hwctx = try driver.createHwctx();
    defer driver.destroyHwctx(hwctx);
}

fn printTileMetadata(name: []const u8, tile: amdxdna.GetInfo.QueryAieMetadata.Tile) void {
    std.debug.print("{s}: row", .{name});
    if (tile.row_count > 1) {
        std.debug.print("s {}:{}", .{ tile.row_start, tile.row_start + tile.row_count - 1 });
    } else std.debug.print(" {}", .{tile.row_start});
    std.debug.print(", dma channels: {}, locks: {}, event regs: {}\n", .{ tile.dma_channel_count, tile.lock_count, tile.event_reg_count });
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

    fn getInfo(self: Self, comptime T: type, param: amdxdna.GetInfo.Param) !T {
        var param_data: T = undefined;
        const get_info = amdxdna.GetInfo{
            .param = param,
            .buffer = @intFromPtr(&param_data),
            .buffer_size = @sizeOf(T),
        };
        try self.ioctl(amdxdna.get_info_ioctl, &get_info);
        return param_data;
    }

    pub fn queryAieMetadata(self: Self) !amdxdna.GetInfo.QueryAieMetadata {
        return self.getInfo(amdxdna.GetInfo.QueryAieMetadata, .query_aie_metadata);
    }

    pub fn queryAieVersion(self: Self) !amdxdna.GetInfo.QueryAieVersion {
        return self.getInfo(amdxdna.GetInfo.QueryAieVersion, .query_aie_version);
    }

    pub fn queryFirmwareVersion(self: Self) !amdxdna.GetInfo.QueryFirmwareVersion {
        return self.getInfo(amdxdna.GetInfo.QueryFirmwareVersion, .query_firmware_version);
    }

    pub fn createBo(self: Self, ty: amdxdna.CreateBo.Type, size: u64) !u32 {
        var create_bo = amdxdna.CreateBo{ .type = ty, .size = size };
        try self.ioctl(amdxdna.create_bo_ioctl, &create_bo);
        return create_bo.handle;
    }

    pub fn destroyBo(self: Self, handle: u32) void {
        const gem_close = drm.GemClose{ .handle = handle };
        self.ioctl(drm.gem_close_ioctl, &gem_close) catch {
            std.log.warn("destroyBo failed\n", .{});
        };
    }

    pub const BoInfo = struct {
        map_offset: u64,
        vaddr: u64,
        xdna_vaddr: u64,
    };

    pub fn getBoInfo(self: Self, handle: u32) !BoInfo {
        var get_bo_info = amdxdna.GetBoInfo{ .handle = handle };
        try self.ioctl(amdxdna.get_bo_info_ioctl, &get_bo_info);
        return .{
            .map_offset = get_bo_info.map_offset,
            .vaddr = get_bo_info.vaddr,
            .xdna_vaddr = get_bo_info.xdna_vaddr,
        };
    }

    pub fn createHwctx(self: Self) !u32 {
        const qos_info = amdxdna.QosInfo{
            .gops = 0,
            .fps = 0,
            .dma_bandwidth = 0,
            .latency = 0,
            .frame_exec_time = 0,
            .priority = 0,
        };
        var create_hwctx = amdxdna.CreateHwctx{
            .qos_p = @intFromPtr(&qos_info),
            .umq_bo = 0,
            .log_buf_bo = 0,
            .max_opc = 0,
            .num_tiles = 6,
            .mem_size = 0,
        };
        try self.ioctl(amdxdna.create_hwctx_ioctl, &create_hwctx);
        return create_hwctx.handle;
    }

    pub fn destroyHwctx(self: Self, handle: u32) void {
        const destroy_hwctx = amdxdna.DestroyHwctx{ .handle = handle };
        self.ioctl(amdxdna.destroy_hwctx_ioctl, &destroy_hwctx) catch {
            std.log.warn("destroyHwctx failed\n", .{});
        };
    }

    pub fn ioctl(self: Self, request: u32, arg: anytype) !void {
        if (std.os.linux.ioctl(self.fd, request, @intFromPtr(arg)) != 0) return error.Fail;
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

        pub const QueryAieMetadata = extern struct {
            col_size: u32,
            cols: u16,
            rows: u16,
            version: QueryAieVersion,
            core: Tile,
            mem: Tile,
            shim: Tile,

            pub const Tile = extern struct {
                row_count: u16,
                row_start: u16,
                dma_channel_count: u16,
                lock_count: u16,
                event_reg_count: u16,
                pad: [3]u16,
            };
        };

        pub const QueryAieVersion = extern struct {
            major: u32,
            minor: u32,
        };

        pub const QueryFirmwareVersion = extern struct {
            major: u32,
            minor: u32,
            patch: u32,
            build: u32,
        };
    };

    pub const SetState = extern struct {
        param: Param,
        buffer_size: u32,
        buffer: u64,

        pub const Param = enum(u32) {
            set_power_mode = 0,
            write_aie_mem = 1,
            write_aie_reg = 2,
        };

        pub const SetPowerMode = extern struct {
            power_mode: Type,
            pad: [7]u8,

            pub const Type = enum(u8) {
                default = 0,
                low = 1,
                medium = 2,
                high = 3,
                turbo = 4,
            };
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
    pub const set_state_ioctl = drm.iowr(drm.command_base + 0x8, SetState);
};

const drm = struct {
    pub const GemClose = extern struct {
        handle: u32,
        pad: u32 = 0,
    };

    pub const ioctl_base = 'd';
    pub const command_base = 0x40;
    pub const gem_close_ioctl = drm.iow(0x09, GemClose);

    pub fn iow(nr: u8, comptime T: type) u32 {
        return std.os.linux.IOCTL.IOW(ioctl_base, nr, T);
    }
    pub fn iowr(nr: u8, comptime T: type) u32 {
        return std.os.linux.IOCTL.IOWR(ioctl_base, nr, T);
    }
};

const std = @import("std");
