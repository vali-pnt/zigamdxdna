pub fn main() !void {
    const fd = try std.posix.open("/dev/accel/accel0", .{}, 0);
    defer std.posix.close(fd);

    const qos = amdxdna.QosInfo{
        .gops = 0,
        .fps = 0,
        .dma_bandwidth = 0,
        .latency = 0,
        .frame_exec_time = 0,
        .priority = 0,
    };
    var create_hwctx = amdxdna.CreateHwctx{
        .qos_p = @intFromPtr(&qos),
        .umq_bo = 0,
        .log_buf_bo = 0,
        .max_opc = 0,
        .num_tiles = 0,
        .mem_size = 0,
    };
    const r = std.os.linux.ioctl(fd, amdxdna.create_hwctx_ioctl, @intFromPtr(&create_hwctx));
    defer {
        const destroy_hwctx = amdxdna.DestroyHwctx{ .handle = create_hwctx.handle };
        _ = std.os.linux.ioctl(fd, amdxdna.destroy_hwctx_ioctl, @intFromPtr(&destroy_hwctx));
    }
    std.debug.print("{}\n = {}\n", .{ create_hwctx, r });
}

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

    pub const create_hwctx_ioctl = drm.iowr(drm.command_base + 0x0, CreateHwctx);
    pub const destroy_hwctx_ioctl = drm.iowr(drm.command_base + 0x1, DestroyHwctx);
};

const drm = struct {
    pub const ioctl_base = 'd';
    pub const command_base = 0x40;

    pub fn iowr(nr: u8, comptime T: type) u32 {
        return std.os.linux.IOCTL.IOWR(ioctl_base, nr, T);
    }
};

const std = @import("std");
