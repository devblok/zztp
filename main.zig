// Copyright (c) 2020 Lukas Praninskas
//
// This software is released under the MIT License.
// https://opensource.org/licenses/MIT

const std = @import("std");
const printf = std.debug.print;
const fs = std.fs;
const os = std.os;
const net = std.net;
const math = std.math;
const Address = std.net.Address;

const dev = @import("./src/dev.zig");
const router = @import("./src/router.zig");

const clap = @import("./extern/zig-clap/clap.zig");

pub fn main() !void {
    const params = comptime [_]clap.Param(clap.Help){
        clap.parseParam("-h, --help             Display this help and exit.") catch unreachable,
        clap.parseParam("-n, --network <IP4>    Network in which the interface will operate.") catch unreachable,
        clap.parseParam("-m, --netmask <IP4>    Netmask for the interface.") catch unreachable,
        clap.parseParam("-a, --address <IP4>    Address of this machine.") catch unreachable,
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

    const file = fs.cwd().openFile(
        "/dev/net/tun",
        .{ .read = true, .write = true },
    ) catch |err| {
        printf("{}\n", .{err});
        return;
    };
    defer file.close();

    var fdev = try dev.TunDevice.init("tun0", file);

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

    var printingPeer = PrintingPeer.init(fdev.device().fd());
    try rt.register(&printingPeer.peer, 0);

    while (true) {
        const run = rt.run() catch |err| {
            switch (err) {
                error.Interrupted => break,
                else => {},
            }
        };
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

/// The definition on an IP packet header.
pub const IP4Hdr = packed struct {
    version: u4,
    internet_header_length: u4,
    type_of_service: u8,
    total_length: u16,
    identification: u16,
    flags: u4,
    frag_offset: u12,
    time_to_live: u8,
    protocol: u8,
    checksum: u16,
    source: [4]u8,
    destination: [4]u8,
};

/// Is a generic handler for source-destination sockets. It can work with any
/// type of socket that read() and write() system calls apply to.
const L3Peer = struct {
    src_sock: i32,
    bufsize: i32,
    peer: router.Peer,

    const Self = @This();

    pub fn init(comptime bufsize: i32, src_sock: i32) SocketPeer {
        return .{
            .src_sock = src_sock,
            .bufsize = bufsize,
            .peer = .{ .socket = src_sock, .handleFn = handle },
        };
    }

    /// Reads from a socket that has data available and immediately writes it out to destination.
    fn handle(peer: *router.Peer, map: *router.AddressMap) router.Error!void {
        const self = @fieldParentPtr(*L3Peer, "peer", peer);

        var buf: [self.bufsize]u8 = undefined;
        const read = os.read(peer.socket, buf[0..]) catch return error.HandlerRead;

        const dest = self.parseDest(buf[0..read]);

        var written: usize = 0;
        while (written < read) {
            written += os.write(self.dst_sock, buf[written..read]) catch |err| {
                // No error to deal with the write contingency, use HandlerRead for now.
                switch (err) {
                    error.AccessDenied => return error.HandlerRead,
                    error.BrokenPipe => return error.HandlerRead,
                    else => continue,
                }
            };
        }
    }

    fn parseDest(self: *Self, buffer: []u8) net.Address {
        return net.Address.parseIp4("0.0.0.0", 0) catch unreachable;
    }
};
