fd: std.posix.fd_t,

const Self = @This();

pub fn init(path: []const u8) !Self {
    const fd = try std.posix.open(path, .{ .ACCMODE = .RDWR, .NONBLOCK = true }, 0);
    return .{ .fd = fd };
}

pub fn deinit(self: Self) void {
    std.posix.close(self.fd);
}

pub fn getInfo(self: Self, comptime T: type, param: xdna.GetInfo.Param) !T {
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
        std.log.warn("destroyBo failed", .{});
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
    self.ioctl(xdna.destroy_hwctx_ioctl, &destroy_hwctx) catch {
        std.log.warn("destroyHwctx failed", .{});
    };
}

pub fn execCmd(self: Self, hwctx: u32, cmd_buf: u32) !u64 {
    var exec_cmd = xdna.ExecCmd{
        .hwctx = hwctx,
        .type = .submit_exec_buf,
        .cmd_handles = cmd_buf,
        .args = 0,
        .cmd_count = 1,
        .arg_count = 0,
    };
    try self.ioctl(xdna.exec_cmd_ioctl, &exec_cmd);
    return exec_cmd.seq;
}

pub fn ioctl(self: Self, request: u32, arg: anytype) !void {
    if (std.os.linux.ioctl(self.fd, request, @intFromPtr(arg)) != 0) return error.Fail;
}

const std = @import("std");
const drm = @import("drm.zig");
const xdna = @import("xdna.zig");
