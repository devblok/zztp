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

const Error = error{Read};

pub fn Device(
    comptime Context: type,
    comptime getFd: fn (context: Context) i32,
) type {
    return struct {
        context: Context,

        const Self = @This();

        pub fn print(self: *Self) void {
            const fd = getFd(self.context);
            printf("Device: {}\n", .{fd});
        }
    };
}

pub const FileDevice = struct {
    file: fs.File,
    name: []const u8,

    const Self = @This();
    const Reader = io.Reader(*Self, Error, read);

    pub fn init(name: []const u8, file: fs.File) os.FcntlError!Self {
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

        printf("Errno: {}\n", .{errno});

        const flag = try os.fcntl(file.handle, os.F_GETFL, 0);
        const fcntlRet = try os.fcntl(file.handle, os.F_SETFL, flag | os.O_NONBLOCK);

        return Self{
            .name = name,
            .file = file,
        };
    }

    pub fn poll(self: *Self, timeout: i32) os.PollError!u64 {
        var pollfd = [_]os.pollfd{
            .{ .fd = self.file.handle, .events = os.POLLIN, .revents = 0 },
        };
        return os.poll(pollfd[0..], timeout);
    }

    pub fn device(self: *Self) Device(*Self, getFd){
        return .{ .context = self };
    }

    fn getFd(self: *Self) i32 {
        return self.file.handle;
    }

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
};

