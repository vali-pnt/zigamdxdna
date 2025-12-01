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

    const dev_heap_size = 64 * 1024 * 1024; // 64MiB
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

    const power_mode = try driver.getInfo(xdna.GetInfo.GetPowerMode, .get_power_mode);
    std.debug.print("power mode: {}\n", .{power_mode.power_mode});

    const cmd_bytes = [_]u8{
        0xff, 0xff, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x24, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x10, 0x00, 0x00, 0x00,
        0x16, 0x00, 0x00, 0x00,
        0x07, 0x00, 0x00, 0x00,
        0xff, 0x00, 0x00, 0x00,
    };
    const cmd_bo = try driver.createBo(.cmd, cmd_bytes.len);
    defer driver.destroyBo(cmd_bo);
    const cmd_bo_info = try driver.getBoInfo(cmd_bo);
    const cmd_mem = try std.posix.mmap(null, cmd_bytes.len, std.os.linux.PROT.READ | std.os.linux.PROT.WRITE, .{ .TYPE = .SHARED, .ANONYMOUS = true }, -1, 0);
    defer std.posix.munmap(cmd_mem);
    const cmd_bo_map = try std.posix.mmap(
        cmd_mem.ptr,
        cmd_bytes.len,
        std.os.linux.PROT.EXEC | std.os.linux.PROT.READ | std.os.linux.PROT.WRITE,
        .{ .TYPE = .SHARED, .LOCKED = true, .FIXED = true },
        driver.fd,
        cmd_bo_info.map_offset,
    );
    defer std.posix.munmap(cmd_bo_map);
    @memcpy(cmd_bo_map, &cmd_bytes);

    const seq = try driver.execCmd(hwctx, cmd_bo);
    std.debug.print("submitted cmd, seq: {}\n", .{seq});
}

fn printTileMetadata(name: []const u8, tile: xdna.GetInfo.QueryAieMetadata.Tile) void {
    std.debug.print("{s}: row", .{name});
    if (tile.row_count > 1) {
        std.debug.print("s {}:{}", .{ tile.row_start, tile.row_start + tile.row_count - 1 });
    } else std.debug.print(" {}", .{tile.row_start});
    std.debug.print(", dma channels: {}, locks: {}, event regs: {}\n", .{ tile.dma_channel_count, tile.lock_count, tile.event_reg_count });
}

const std = @import("std");
const drm = @import("drm.zig");
const xdna = @import("xdna.zig");
const Driver = @import("Driver.zig");
