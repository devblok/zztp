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
};

pub fn Device(
    comptime Context: type,
    comptime nameFn: fn (context: Context) []const u8,
    comptime getFd: fn (context: Context) i32,
    comptime routeFn: fn (name: []const u8, info: IfRouteInfo) Error!void,
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
        pub fn route(self: Self, info: IfRouteInfo) Error!void {
            return routeFn(nameFn(self.context), info);
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
    const Dev = Device(*Self, name, getFd, virtIfRoute, close);

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
pub const IfRouteInfo = struct {
    address: os.sockaddr,
    netmask: os.sockaddr,
};

/// Prototype for the device router.
fn virtIfRoute(name: []const u8, info: IfRouteInfo) Error!void {
    var ifr_name = [_]u8{0} ** c.IFNAMSIZ;
    mem.copy(u8, ifr_name[0..c.IFNAMSIZ], name[0..]);

    var ifr = os.linux.ifreq{
        .ifrn = .{
            .name = ifr_name,
        },
        .ifru = .{
            .addr = info.address,
        },
    };

    var errno = os.system.ioctl(c.AF_INET, c.SIOCSIFADDR, @ptrToInt(&ifr));
    if (errno != 0) {
        return error.IfConfig;
    }

    ifr = os.linux.ifreq{
        .ifrn = .{
            .name = ifr_name,
        },
        .ifru = .{
            .addr = info.netmask,
        },
    };

    errno = os.system.ioctl(c.AF_INET, c.SIOCSIFNETMASK, @ptrToInt(&ifr));
    if (errno != 0) {
        return error.IfConfig;
    }
}
