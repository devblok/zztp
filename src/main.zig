// Copyright (c) 2020 Lukas Praninskas
//
// This software is released under the MIT License.
// https://opensource.org/licenses/MIT

const std = @import("std");
const printf = std.debug.print;
const fs = std.fs;

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

    var fdev = try dev.FileDevice.init("tun0", file);
    fdev.device().print();

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
