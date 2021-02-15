// Copyright (c) 2020 Lukas Praninskas
//
// This software is released under the MIT License.
// https://opensource.org/licenses/MIT

const std = @import("std");
const printf = std.debug.print;
const fs = std.fs;
const os = std.os;
const net = std.net;
const fmt = std.fmt;
const math = std.math;
const Address = std.net.Address;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

const dev = @import("./src/dev.zig");
const router = @import("./src/router.zig");
const l3tun = @import("./src/l3tun.zig");

const clap = @import("./extern/zig-clap/clap.zig");

pub const io_mode = .evented;

pub fn main() !void {
    @setEvalBranchQuota(5000);
    const params = comptime [_]clap.Param(clap.Help){
        clap.parseParam("-h, --help             Display this help and exit.") catch unreachable,
        clap.parseParam("-n, --network <IP4>    Network in which the interface will operate.") catch unreachable,
        clap.parseParam("-m, --netmask <IP4>    Netmask for the interface.") catch unreachable,
        clap.parseParam("-a, --address <IP4>    Address of this machine.") catch unreachable,
        clap.parseParam("-d, --device <NAME>    Device name to use for the tunnel.") catch unreachable,
        clap.parseParam("-p, --port <PORT>      Port number to listen on.") catch unreachable,
        clap.parseParam("-c, --connect <IP>     Connect to a server, port defined by the p flag.") catch unreachable,
        clap.parseParam("<POS>...") catch unreachable,
    };

    var diag: clap.Diagnostic = undefined;
    var args = clap.parse(clap.Help, &params, std.heap.page_allocator, &diag) catch |err| {
        diag.report(std.io.getStdErr().outStream(), err) catch {};
        return err;
    };
    defer args.deinit();

    if (args.flag("--help")) {
        try clap.help(std.io.getStdErr().outStream(), &params);
        return;
    }

    var portArg: u16 = 0;
    if (args.option("--port")) |port| {
        portArg = try fmt.parseInt(u16, port, 10);
    } else {
        portArg = 8080;
    }

    const file = fs.cwd().openFile(
        "/dev/net/tun",
        .{ .read = true, .write = true },
    ) catch |err| {
        printf("{}\n", .{err});
        return;
    };
    defer file.close();

    var deviceArg: []const u8 = undefined;
    if (args.option("--device")) |device| {
        deviceArg = device;
    } else {
        deviceArg = "tun0";
    }

    var fdev = try dev.TunDevice.init(deviceArg, file);

    var addressArg: []const u8 = undefined;
    if (args.option("--address")) |addr| {
        addressArg = addr;
    } else {
        printf("Address option is missing\n", .{});
        return;
    }

    var netmaskArg: []const u8 = undefined;
    if (args.option("--netmask")) |mask| {
        netmaskArg = mask;
    } else {
        printf("Netmask option is missing\n", .{});
        return;
    }

    const netmask = try Address.parseIp(netmaskArg, 0);
    const address = try Address.parseIp(addressArg, 0);
    const routeInfo = dev.IfConfigInfo{
        .address = address.any,
        .netmask = netmask.any,
    };

    try fdev.device().ifcfg(routeInfo);

    const allocator = std.heap.page_allocator;
    var rt = try router.Router.init(allocator, 10, 100);
    defer rt.deinit();

    var buf: [65536]u8 = undefined;
    var p = l3tun.L3Peer.init(fdev.device().fd(), buf[0..]);
    try rt.register(&p.peer, 0);

    var run = async routerRun(&rt);
    serverListen(allocator, portArg, &rt) catch |err| printf("Error {}\n", .{err});
    try await run;
}

fn routerRun(r: *router.Router) !void {
    while (true) {
        r.run() catch |err| {
            switch (err) {
                error.Interrupted => return err,
                else => {},
            }
        };
    }
}

fn serverListen(allocator: *Allocator, port: u16, r: *router.Router) !void {
    const sock = try os.socket(os.AF_INET, os.SOCK_STREAM, 0);
    defer os.close(sock);

    var server = net.StreamServer.init(.{});
    defer server.deinit();

    const address = try Address.parseIp4("0.0.0.0", port);
    try server.listen(address);

    var list = ArrayList(l3tun.L3Peer).init(allocator);
    defer {
        for (list.items) |peer| {
            allocator.free(peer.buffer);
        }
        list.deinit();
    }

    while (true) {
        const conn = try server.accept();

        var p = l3tun.L3Peer.init(conn.file.handle, try allocator.alloc(u8, 65536));
        try list.append(p);

        try r.register(&p.peer, 0);
    }
}

const PrintingPeer = struct {
    peer: router.Peer,

    const Self = @This();

    pub fn init(socket_fd: i32) PrintingPeer {
        return .{
            .peer = .{
                .socket = socket_fd,
                .handleFn = handle,
                .address = net.Address.parseIp4("0.0.0.0", 0) catch unreachable,
            },
        };
    }

    fn handle(peer: *router.Peer, map: *router.AddressMap) router.Error!void {
        const self = @fieldParentPtr(Self, "peer", peer);

        var buf: [1024]u8 = undefined;
        const count = os.read(peer.socket, buf[0..]) catch return error.HandlerRead;

        printf("Read {} bytes: {}\n", .{ count, buf[0..count] });
    }
};
