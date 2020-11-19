// Copyright (c) 2020 Lukas Praninskas
//
// This software is released under the MIT License.
// https://opensource.org/licenses/MIT

const std = @import("std");
const printf = std.debug.print;
const fs = std.fs;
const os = std.os;
const math = std.math;
const Address = std.net.Address;

const dev = @import("./src/dev.zig");

const clap = @import("./extern/zig-clap/clap.zig");

pub fn main() !void {
    const params = comptime [_]clap.Param(clap.Help){
        clap.parseParam("-n, --network <IP4>    Network in which the interface will operate.") catch unreachable,
        clap.parseParam("-m, --netmask <IP4>    Netmask for the interface.") catch unreachable,
        clap.parseParam("-a, --address <IP4>    Address of this machine.") catch unreachable,
    };

    var diag: clap.Diagnostic = undefined;
    var args = clap.parse(clap.Help, &params, std.heap.page_allocator, &diag) catch |err| {
        diag.report(std.io.getStdErr().outStream(), err) catch {};
        return err;
    };
    defer args.deinit();

    const file = fs.cwd().openFile(
        "/dev/net/tun",
        .{ .read = true, .write = true },
    ) catch |err| {
        printf("{}\n", .{err});
        return;
    };
    defer file.close();

    const network = try Address.parseIp("172.1.0.0", 0);
    const netmask = try Address.parseIp("255.255.255.0", 0);
    const address = try Address.parseIp("172.1.0.1", 0);

    var fdev = try dev.TunDevice.init("tun0", file, &network.any, &netmask.any, &address.any);

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
