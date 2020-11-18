// Copyright (c) 2020 Lukas Praninskas
//
// This software is released under the MIT License.
// https://opensource.org/licenses/MIT

const std = @import("std");
const printf = std.debug.print;
const fs = std.fs;
const os = std.os;
const math = std.math;

const dev = @import("./dev.zig");

pub fn main() !void {
    const file = fs.cwd().openFile(
        "/dev/net/tun",
        .{ .read = true, .write = true },
    ) catch |err| {
        printf("{}\n", .{err});
        return;
    };
    defer file.close();

    const network = os.sockaddr_in{
        .family = os.AF_INET,
        .port = 0,
        .addr = 0,
    };

    const netmask = os.sockaddr_in{
        .family = os.AF_INET,
        .port = 0,
        .addr = math.maxInt(u32),
    };

    const address = os.sockaddr_in{
        .family = os.AF_INET,
        .port = 0,
        .addr = 1,
    };

    var fdev = try dev.TunDevice.init(
        "tun0",
        file,
        @ptrCast(*const os.sockaddr, &network),
        @ptrCast(*const os.sockaddr, &netmask),
        @ptrCast(*const os.sockaddr, &address),
    );

    var buf: [1024]u8 = undefined;
    while (true) {
        const poll = fdev.poll(500000) catch |err| {
            printf("Poll err {}\n", .{err});
            break;
        };
        printf("Poll {}\n", .{poll});

        const count = fdev.reader().read(&buf) catch |err| {
            printf("Read err {}\n", .{err});
            break;
        };
        printf("Read {} bytes: {}\n", .{ count, buf[0..count] });
    }
}
