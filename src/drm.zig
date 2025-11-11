pub const GemClose = extern struct {
    handle: u32,
    pad: u32 = 0,
};

pub const ioctl_base = 'd';
pub const command_base = 0x40;
pub const gem_close_ioctl = iow(0x09, GemClose);

pub fn iow(nr: u8, comptime T: type) u32 {
    return std.os.linux.IOCTL.IOW(ioctl_base, nr, T);
}
pub fn iowr(nr: u8, comptime T: type) u32 {
    return std.os.linux.IOCTL.IOWR(ioctl_base, nr, T);
}

const std = @import("std");
