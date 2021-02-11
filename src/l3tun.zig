// Copyright (c) 2021 Lukas Praninskas
//
// This software is released under the MIT License.
// https://opensource.org/licenses/MIT

const std = @import("std");
const os = std.os;
const net = std.net;
const print = std.debug.print;
const Address = net.Address;

const router = @import("./router.zig");

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
/// type of socket that read() and write() system calls apply to. Works for a TUN interface.
const L3Peer = struct {
    peer: router.Peer,

    const Self = @This();

    pub fn init(src_sock: i32) Self {
        return .{
            .peer = .{
                .socket = src_sock,
                .address = net.Address.initIp4([4]u8{ 0, 0, 0, 0 }, 0),
                .handleFn = handle,
            },
        };
    }

    /// Reads from a socket that has data available and immediately writes it out to destination.
    fn handle(peer: *router.Peer, map: *router.AddressMap) router.Error!void {
        const self = @fieldParentPtr(L3Peer, "peer", peer);

        var buf: [100]u8 = undefined;
        const read = os.read(peer.socket, buf[0..]) catch return error.HandlerRead;

        const dest = self.parseDest(buf[0..read]);
        if (map.map.get(Address.initIp4([4]u8{ 0, 0, 0, 0 }, 0).any)) |dst_sock| {
            var written: usize = 0;
            while (written < read) {
                written += os.write(dst_sock, buf[written..read]) catch |err| {
                    // No error to deal with the write contingency, use HandlerRead for now.
                    switch (err) {
                        error.AccessDenied => return error.HandlerRead,
                        error.BrokenPipe => return error.HandlerRead,
                        else => continue,
                    }
                };
            }
        }
    }

    fn parseDest(self: *Self, buffer: []u8) net.Address {
        return net.Address.parseIp4("0.0.0.0", 0) catch unreachable;
    }
};

const testing = std.testing;
const expect = testing.expect;
const mem = std.mem;

test "writes data" {
    const allocator = std.heap.page_allocator;

    const inPipes = try os.pipe();
    defer os.close(inPipes[0]);
    defer os.close(inPipes[1]);

    const outPipes = try os.pipe();
    defer os.close(outPipes[0]);
    defer os.close(outPipes[1]);

    var map = router.AddressMap.init(allocator);
    defer map.deinit(allocator);

    var addr = Address.initIp4([4]u8{ 0, 0, 0, 0 }, 0);
    try map.map.put(allocator, addr.any, outPipes[1]);

    var inbuf: [100]u8 = undefined;
    const bytesWritten = try os.write(inPipes[1], inbuf[0..]);
    print("{} bytes written\n", .{bytesWritten});

    var peer = L3Peer.init(inPipes[0]);
    try peer.peer.handle(&map);

    var outbuf: [100]u8 = undefined;
    const bytesRead = try os.read(outPipes[0], outbuf[0..]);
    print("{} bytes read\n", .{bytesRead});
}

test "parses IP header" {
    var data = [_]u8{
        0x45, // ver + hdr
        0x00, // dcsp + ecn
        0x00, 0x19, // total len
        0x10, 0x10, // id
        0x40, 0x00, // flags + frag offset
        0x40, // ttl
        0x06, // protocol
        0x7c, 0x2c, // crc
        192, 168, 1, 1, // src
        172, 168, 2,   32, // dst
        'H', 'e', 'l', 'l',
        'o',
    };

    const hdr = @ptrCast(*IP4Hdr, &data);

    const want = [4]u8{ 172, 168, 2, 32 };
    expect(mem.eql(u8, hdr.destination[0..], want[0..]));
}
