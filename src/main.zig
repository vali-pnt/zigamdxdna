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
    const dev_heap_mem = try std.posix.mmap(null, dev_heap_size * 2, std.os.linux.PROT.READ | std.os.linux.PROT.WRITE, .{ .TYPE = .SHARED, .ANONYMOUS = true }, -1, 0);
    defer std.posix.munmap(dev_heap_mem);
    const dev_heap_addr = std.mem.alignForward(usize, @intFromPtr(dev_heap_mem.ptr), dev_heap_size);
    const dev_heap_bo_map = try std.posix.mmap(
        @ptrFromInt(dev_heap_addr),
        dev_heap_size,
        std.os.linux.PROT.EXEC | std.os.linux.PROT.READ | std.os.linux.PROT.WRITE,
        .{ .TYPE = .SHARED, .LOCKED = true, .FIXED = true },
        driver.fd,
        dev_heap_bo_info.map_offset,
    );
    defer std.posix.munmap(dev_heap_bo_map);

    const hwctx = try driver.createHwctx();
    defer driver.destroyHwctx(hwctx);
}

fn printTileMetadata(name: []const u8, tile: xdna.GetInfo.QueryAieMetadata.Tile) void {
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

    fn getInfo(self: Self, comptime T: type, param: xdna.GetInfo.Param) !T {
        var param_data: T = undefined;
        const get_info = xdna.GetInfo{
            .param = param,
            .buffer = @intFromPtr(&param_data),
            .buffer_size = @sizeOf(T),
        };
        try self.ioctl(xdna.get_info_ioctl, &get_info);
        return param_data;
    }

    pub fn queryAieMetadata(self: Self) !xdna.GetInfo.QueryAieMetadata {
        return self.getInfo(xdna.GetInfo.QueryAieMetadata, .query_aie_metadata);
    }

    pub fn queryAieVersion(self: Self) !xdna.GetInfo.QueryAieVersion {
        return self.getInfo(xdna.GetInfo.QueryAieVersion, .query_aie_version);
    }

    pub fn queryFirmwareVersion(self: Self) !xdna.GetInfo.QueryFirmwareVersion {
        return self.getInfo(xdna.GetInfo.QueryFirmwareVersion, .query_firmware_version);
    }

    pub fn createBo(self: Self, ty: xdna.CreateBo.Type, size: u64) !u32 {
        var create_bo = xdna.CreateBo{ .type = ty, .size = size };
        try self.ioctl(xdna.create_bo_ioctl, &create_bo);
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
        var get_bo_info = xdna.GetBoInfo{ .handle = handle };
        try self.ioctl(xdna.get_bo_info_ioctl, &get_bo_info);
        return .{
            .map_offset = get_bo_info.map_offset,
            .vaddr = get_bo_info.vaddr,
            .xdna_vaddr = get_bo_info.xdna_vaddr,
        };
    }

    pub fn createHwctx(self: Self) !u32 {
        const qos_info = xdna.QosInfo{
            .gops = 100,
            .fps = 0,
            .dma_bandwidth = 0,
            .latency = 0,
            .frame_exec_time = 0,
            .priority = 384,
        };
        var create_hwctx = xdna.CreateHwctx{
            .qos_p = @intFromPtr(&qos_info),
            .umq_bo = 0,
            .log_buf_bo = 0,
            .max_opc = 8192,
            .num_tiles = 16,
            .mem_size = 0,
        };
        try self.ioctl(xdna.create_hwctx_ioctl, &create_hwctx);
        return create_hwctx.handle;
    }

    pub fn destroyHwctx(self: Self, handle: u32) void {
        const destroy_hwctx = xdna.DestroyHwctx{ .handle = handle };
        self.ioctl(xdna.destroy_hwctx_ioctl, &destroy_hwctx) catch {};
    }

    pub fn ioctl(self: Self, request: u32, arg: anytype) !void {
        if (std.os.linux.ioctl(self.fd, request, @intFromPtr(arg)) != 0) return error.Fail;
    }
};

const std = @import("std");
const drm = @import("drm.zig");
const xdna = @import("xdna.zig");
