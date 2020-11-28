// Copyright (c) 2020 Lukas Praninskas
//
// This software is released under the MIT License.
// https://opensource.org/licenses/MIT

const std = @import("std");
const printf = std.debug.print;
const fs = std.fs;
const os = std.os;
const io = std.io;
const mem = std.mem;

const c = @cImport({
    @cInclude("sys/ioctl.h");
    @cInclude("linux/if_tun.h");
    @cInclude("net/if.h");
});

const Error = error{
    Create,
    Read,
    IfConfig,
    GetInet,
    DeviceGone,
    BadDevice,
};

pub fn Device(
    comptime Context: type,
    comptime nameFn: fn (context: Context) []const u8,
    comptime getFd: fn (context: Context) i32,
    comptime ifcfgFn: fn (name: []const u8, info: IfConfigInfo) Error!void,
    comptime closeFn: fn (context: Context) void,
) type {
    return struct {
        context: Context,

        const Self = @This();

        /// Returns the name of the interface.
        pub fn name(self: Self) []const u8 {
            return nameFn(self.context);
        }

        /// Return a file descriptor for the already configured device.
        pub fn fd(self: Self) i32 {
            return getFd(self.context);
        }

        /// Route the device for the system.
        pub fn ifcfg(self: Self, info: IfConfigInfo) Error!void {
            return ifcfgFn(nameFn(self.context), info);
        }

        // Finalizes and closes the device, undoing all of it's configuration.
        pub fn close(self: Self) void {
            closeFn(self.context);
        }
    };
}

pub const TunDevice = struct {
    file: fs.File,
    name: []const u8,

    const Self = @This();
    const Reader = io.Reader(*Self, Error, read);
    const Dev = Device(*Self, name, getFd, virtifcfg, close);

    /// Creates, initializes and configures a virtual TUN device
    /// with a given name, clone file device descriptor, network,
    /// netmask and a concrete IP address.
    pub fn init(
        deviceName: []const u8,
        file: fs.File,
    ) !Self {
        var ifr_name = [_]u8{0} ** c.IFNAMSIZ;
        mem.copy(u8, ifr_name[0..c.IFNAMSIZ], deviceName[0..]);

        const ifr = os.linux.ifreq{
            .ifrn = .{
                .name = ifr_name,
            },
            .ifru = .{
                .flags = c.IFF_TUN,
            },
        };

        const errno = os.linux.ioctl(file.handle, c.TUNSETIFF, @ptrToInt(&ifr));
        if (errno != 0) {
            return error.Create;
        }

        const flag = try os.fcntl(file.handle, os.F_GETFL, 0);
        const fcntlRet = try os.fcntl(file.handle, os.F_SETFL, flag | os.O_NONBLOCK);

        return Self{
            .name = deviceName,
            .file = file,
        };
    }

    pub fn device(self: *Self) Dev {
        return .{ .context = self };
    }

    /// Get the name of the interface.
    fn name(self: *Self) []const u8 {
        return self.name;
    }

    // Returns the file device.
    fn getFd(self: *Self) i32 {
        return self.file.handle;
    }

    /// Closes the underlying file device.
    fn close(self: *Self) void {
        self.file.close();
    }

    ///============DEPRECATED PAST THIS POINT=============
    pub fn reader(self: *Self) Reader {
        return .{ .context = self };
    }

    fn read(self: *Self, buffer: []u8) Error!usize {
        const count = self.file.read(buffer) catch |err| {
            printf("Read error {}\n", .{err});
            return Error.Read;
        };
        return count;
    }

    pub fn poll(self: *Self, timeout: i32) os.PollError!u64 {
        var pollfd = [_]os.pollfd{
            .{ .fd = self.file.handle, .events = os.POLLIN, .revents = 0 },
        };
        return os.poll(pollfd[0..], timeout);
    }
};

/// Contains all the nescesary information to configure a network interface.
pub const IfConfigInfo = struct {
    address: os.sockaddr,
    netmask: os.sockaddr,
};

/// Configures and ups the virtual network interface.
fn virtifcfg(name: []const u8, info: IfConfigInfo) Error!void {
    const flags = os.SOCK_DGRAM | os.SOCK_CLOEXEC | os.SOCK_NONBLOCK;
    const fd = os.socket(os.AF_INET, flags, 0) catch |err| {
        return error.GetInet;
    };

    var ifr_name = [_]u8{0} ** c.IFNAMSIZ;
    mem.copy(u8, ifr_name[0..c.IFNAMSIZ], name[0..]);

    try doIoctl(fd, c.SIOCSIFADDR, @ptrToInt(&os.linux.ifreq{
        .ifrn = .{
            .name = ifr_name,
        },
        .ifru = .{
            .addr = info.address,
        },
    }));

    try doIoctl(fd, c.SIOCSIFNETMASK, @ptrToInt(&os.linux.ifreq{
        .ifrn = .{
            .name = ifr_name,
        },
        .ifru = .{
            .addr = info.netmask,
        },
    }));

    try doIoctl(fd, c.SIOCSIFFLAGS, @ptrToInt(&os.linux.ifreq{
        .ifrn = .{
            .name = ifr_name,
        },
        .ifru = .{
            .flags = 1 | c.IFF_UP,
        },
    }));
}

fn doIoctl(fd: i32, flags: u16, addr: u64) Error!void {
    switch (os.errno(os.system.ioctl(fd, flags, addr))) {
        0 => return,
        os.EBADF => return error.DeviceGone,
        os.EFAULT => return error.IfConfig,
        os.EINVAL => return error.IfConfig,
        os.ENOTTY => return error.BadDevice,
        os.ENXIO => unreachable,
        os.EINTR => unreachable,
        os.EIO => unreachable,
        os.ENODEV => unreachable,
        else => return error.IfConfig,
    }
}
