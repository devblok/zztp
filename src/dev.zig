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
};

pub fn Device(
    comptime Context: type,
    comptime getFd: fn (context: Context) i32,
    comptime routeFn: fn (context: Context) Error!void,
    comptime closeFn: fn (context: Context) void,
) type {
    return struct {
        context: Context,

        const Self = @This();

        /// Return a file descriptor for the already configured device.
        pub fn fd(self: Context) i32 {
            return getFd(self);
        }

        /// Route the device for the system.
        pub fn route(self: Context) Error!void {
            return routeFn(self);
        }

        // Finalizes and closes the device, undoing all of it's configuration.
        pub fn close(self: Context) void {
            close(self);
        }
    };
}

pub const TunDevice = struct {
    file: fs.File,
    name: []const u8,

    const Self = @This();
    const Reader = io.Reader(*Self, Error, read);
    const Device = Device(*Self, getFd, virtIfRoute, close);

    /// Creates, initializes and configures a virtual TUN device
    /// with a given name, clone file device descriptor, network,
    /// netmask and a concrete IP address.
    pub fn init(
        name: []const u8,
        file: fs.File,
        network: *const os.sockaddr,
        netmask: *const os.sockaddr,
        address: *const os.sockaddr,
    ) !Self {
        var ifr_name = [_]u8{0} ** c.IFNAMSIZ;
        mem.copy(u8, ifr_name[0..c.IFNAMSIZ], name[0..]);

        const ifr = c.ifreq{
            .ifr_ifrn = .{
                .ifrn_name = ifr_name,
            },
            .ifr_ifru = .{
                .ifru_flags = c.IFF_TUN,
            },
        };

        const errno = os.linux.ioctl(
            file.handle,
            c.TUNSETIFF,
            @ptrToInt(&ifr),
        );

        if (errno != 0) {
            return error.Create;
        }

        const flag = try os.fcntl(file.handle, os.F_GETFL, 0);
        const fcntlRet = try os.fcntl(file.handle, os.F_SETFL, flag | os.O_NONBLOCK);

        return Self{
            .name = name,
            .file = file,
        };
    }

    pub fn device(self: *Self) Device {
        return .{ .context = self };
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

/// Prototype for the device router.
fn virtIfRoute(comptime context: Context) void {}
