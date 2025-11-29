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

    pub const CuConfig = extern struct {
        cu_bo: u32,
        cu_func: u8,
        pad: [3]u8 = std.mem.zeroes([3]u8),
    };

    pub const ConfigCu = extern struct {
        num_cus: u16,
        pad: [3]u16 = std.mem.zeroes([3]u16),
        cu_configs: [0]CuConfig,

        pub fn init(gpa: std.mem.Allocator, cu_configs: []CuConfig) !*ConfigCu {
            const bytes = try gpa.alloc(u8, @sizeOf(ConfigCu) + @sizeOf(CuConfig) * cu_configs.len);
            const self: *ConfigCu = @ptrCast(bytes.ptr);
            self.num_cus = @intCast(cu_configs.len);
            const configs: [*]ConfigCu = @ptrCast(&self.cu_configs);
            @memcpy(configs, cu_configs);
            return self;
        }

        pub fn deinit(self: *ConfigCu, gpa: std.mem.Allocator) void {
            gpa.free(@as([*]u8, @ptrCast(self))[0..self.num_cus]);
        }

        pub fn getCuConfigs(self: *ConfigCu) []CuConfig {
            return @as([*]ConfigCu, @ptrCast(&self.cu_configs))[0..self.num_cus];
        }
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

pub const PowerModeType = enum(u8) {
    default = 0,
    low = 1,
    medium = 2,
    high = 3,
    turbo = 4,
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

    pub const QueryAieStatus = extern struct {
        buffer: u64,
        buffer_size: u32,
        cols_filled: u32,
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
            pad: [3]u16 = std.mem.zeroes([3]u16),
        };
    };

    pub const QueryAieVersion = extern struct {
        major: u32,
        minor: u32,
    };

    pub const QueryClockMetadata = extern struct {
        mp_npu_clock: Clock,
        h_clock: Clock,

        pub const Clock = extern struct {
            name: [16]u8,
            freq_mhz: u32,
            pad: u32 = 0,
        };
    };

    pub const QuerySensor = extern struct {
        label: [64]u8,
        input: u32,
        max: u32,
        average: u32,
        highest: u32,
        status: [64]u8,
        units: [16]u8,
        unitm: i8,
        type: Type,
        pad: [6]u8 = std.mem.zeroes([6]u8),

        pub const Type = enum(u8) {
            power = 0,
        };
    };

    pub const QueryHwContext = extern struct {
        context_id: u32,
        start_col: u32,
        num_col: u32,
        pad: u32 = 0,
        pid: i64,
        command_submissions: u64,
        command_completions: u64,
        migrations: u64,
        preemptions: u64,
        errors: u64,
    };

    pub const QueryFirmwareVersion = extern struct {
        major: u32,
        minor: u32,
        patch: u32,
        build: u32,
    };

    pub const GetPowerMode = extern struct {
        power_mode: PowerModeType,
        pad: [7]u8 = std.mem.zeroes([7]u8),
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
        power_mode: PowerModeType,
        pad: [7]u8 = std.mem.zeroes([7]u8),
    };
};

pub const GetArray = extern struct {
    param: Param,
    element_size: u32,
    num_element: u32,
    pad: u32 = 0,
    buffer: u64,

    pub const Param = enum(u32) {
        hw_context_all = 0,
    };

    pub const HwContextEntry = extern struct {
        context_id: u32,
        start_col: u32,
        num_col: u32,
        hwctx_id: u32,
        pid: i64,
        command_submissions: u64,
        command_completions: u64,
        migrations: u64,
        preemptions: u64,
        errors: u64,
        priority: u64,
        heap_usage: u64,
        suspensions: u64,
        state: State,
        pasid: u32,
        gops: u32,
        fps: u32,
        dma_bandwidth: u32,
        latency: u32,
        frame_exec_time: u32,
        txn_op_idx: u32,
        ctx_pc: u32,
        fatal_error_type: u32,
        fatal_error_exception_type: u32,
        fatal_error_exception_pc: u32,
        fatal_error_app_module: u32,
        pad: u32 = 0,

        pub const State = enum(u32) {
            idle = 0,
            active = 1,
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
pub const get_info_ioctl = drm.iowr(drm.command_base + 0x7, GetInfo);
pub const set_state_ioctl = drm.iowr(drm.command_base + 0x8, SetState);
pub const get_array_ioctl = drm.iowr(drm.command_base + 0xa, GetArray);

const std = @import("std");
const drm = @import("drm.zig");
