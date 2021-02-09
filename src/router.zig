// Copyright (c) 2020 Lukas Praninskas
//
// This software is released under the MIT License.
// https://opensource.org/licenses/MIT

const std = @import("std");
const os = std.os;
const assert = std.debug.assert;
const Address = std.net.Address;
const Allocator = std.mem.Allocator;

// What a router should do:
// 1. Poll and wait for a file descriptor to be ready
// 2. Read the available data to buffer
// 3. Interpret the IP packet header
// 4. Assert the correct destination of the arriving packet
// 5. Pass it to the transport that will take care of sending it
// 6. Repeat.
// Misc. Allow insertion and deletion of clients from the loop

pub const Error = error{ Interrupted, HandlerRead, Resources, NoHandler };

/// The definition for the router function that finds the destination
/// socket from a given Address structure.
pub const GetSock = fn (Address) Error!i32;

/// A representation of a Router peer.
pub const Peer = struct {
    socket: i32,
    address: Address,
    handleFn: fn (self: *Self, map: *AddressMap) Error!void,

    const Self = @This();

    pub fn handle(self: *Self, map: *AddressMap) Error!void {
        return self.handleFn(self, map);
    }
};

pub const AddressMap = struct {
    map: MapType,
    lock: std.Mutex,

    const Self = @This();
    const MapType = std.AutoHashMapUnmanaged([50]u8, i32);

    pub fn init(allocator: *Allocator) AddressMap {
        return .{
            .map = MapType.init(allocator),
            .lock = .{},
        };
    }

    pub fn deinit(self: *Self, allocator: *Allocator) void {
        self.map.deinit(allocator);
    }
};

/// Implements the packet handling mechanism.
pub const Router = struct {
    epoll_fd: i32,
    epoll_timeout: i32,
    max_concurrent: u32,

    allocator: *Allocator,
    peers_lock: std.Mutex,
    peers: PeerMap,

    addresses: AddressMap,

    const Self = @This();
    const PeerMap = std.AutoHashMapUnmanaged(i32, *Peer);

    /// Starts processing the incoming packets and writing them. Will exit after a configured timeout,
    /// so it must be continously run in a loop with quick successions with optional status checking before etc.
    pub fn run(self: *Self) Error!void {
        const events = self.allocator.alloc(os.epoll_event, self.max_concurrent) catch return error.Resources;
        defer self.allocator.free(events);

        try self.epollProc(events);
    }

    /// Register a handler so that it could start participating in the routing process.
    /// First, we insert the handler into the map, only later activating it via epoll.
    ///
    /// It accepts a handler and epoll flags that will influence the behaviour of signalling.
    /// Leaving flags to zero will result in a correct default behaviour. Polling for write
    /// availability is disallowed and will crash.
    pub fn register(self: *Self, peer: *Peer, flags: u32) !void {
        // We do not want to poll for write availability.
        assert(flags & os.EPOLLOUT == 0);

        const lock = self.peers_lock.acquire();
        defer lock.release();

        self.peers.put(self.allocator, peer.socket, peer) catch |err| {
            switch (err) {
                error.OutOfMemory => return error.Resources,
                else => return err,
            }
        };

        var ee = os.linux.epoll_event{
            .events = flags | os.EPOLLIN,
            .data = .{ .fd = peer.socket },
        };
        try os.epoll_ctl(self.epoll_fd, os.EPOLL_CTL_ADD, peer.socket, &ee);
    }

    /// Removes the handler from routing. It's first disabled via epoll, to prevent
    /// the routing process from trying to access it. Only then it is removed from the map.
    pub fn unregister(self: *Self, peer: *Peer) void {
        const lock = self.peers_lock.acquire();
        defer lock.release();

        os.epoll_ctl(self.epoll_fd, os.EPOLL_CTL_DEL, peer.socket, null) catch {};
        _ = self.peers.remove(peer.socket);
    }

    pub fn init(allocator: *Allocator, max_concurrent: u32, epoll_timeout: i32) !Self {
        return Self{
            .epoll_fd = try os.epoll_create1(0),
            .epoll_timeout = epoll_timeout,
            .max_concurrent = max_concurrent,
            .allocator = allocator,
            .peers = PeerMap.init(allocator),
            .peers_lock = std.Mutex{},
            .addresses = AddressMap.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        os.close(self.epoll_fd);
        self.peers.deinit(self.allocator);
        self.addresses.deinit(self.allocator);
    }

    fn epollProc(self: *Self, e: []os.epoll_event) Error!void {
        var ret: usize = 0;
        var first: bool = true;
        while (ret > 0 or first) : (ret = os.epoll_wait(self.epoll_fd, e, self.epoll_timeout)) {
            for (e[0..ret]) |event| {
                try self.execHandler(event);
            }
            first = false;
        }
    }

    fn execHandler(self: *Self, event: os.epoll_event) Error!void {
        var peerEntry: ?*Peer = undefined;

        if (self.peers_lock.tryAcquire()) |lock| {
            peerEntry = self.peers.get(event.data.fd);
            lock.release();
        }

        if (peerEntry) |peer| {
            peer.handle(&self.addresses) catch |err| {
                switch (err) {
                    error.HandlerRead => self.unregister(peer),
                    error.Interrupted => unreachable,
                    error.Resources => unreachable,
                    error.NoHandler => unreachable,
                }
            };
        } else {
            return error.NoHandler;
        }
    }
};

const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectEqualStrings = testing.expectEqualStrings;
const expectError = testing.expectError;
const FailingAllocator = testing.FailingAllocator;

const MockPeer = struct {
    ret_error: bool,
    handle_count: i32,
    last_byte_count: usize,
    last_content: [128:0]u8,
    peer: Peer,

    const Self = @This();

    pub fn init(socket: i32, addr: Address, ret_error: bool) Self {
        return .{
            .ret_error = ret_error,
            .handle_count = 0,
            .last_byte_count = 0,
            .last_content = [_:0]u8{0} ** 128,
            .peer = .{
                .address = addr,
                .socket = socket,
                .handleFn = handle,
            },
        };
    }

    fn handle(peer: *Peer, map: *AddressMap) Error!void {
        const self = @fieldParentPtr(Self, "peer", peer);

        self.handle_count += 1;

        if (self.ret_error) {
            return error.HandlerRead;
        }

        self.last_byte_count = os.read(peer.socket, self.last_content[0..]) catch |err| return error.HandlerRead;
    }
};

test "epoll" {
    var router = try Router.init(std.heap.page_allocator, 1, 100);
    defer router.deinit();

    const pipes = try os.pipe();
    defer os.close(pipes[0]);
    defer os.close(pipes[1]);

    const address = try Address.parseIp4("172.1.0.1", 0);

    var mock = MockPeer.init(pipes[0], address, false);
    try router.register(&mock.peer, 0);

    const written = try os.write(pipes[1], "hello world!");
    expectEqual(@intCast(usize, 12), written);

    try router.run();

    expectEqual(@intCast(i32, 1), mock.handle_count);
    expectEqual(@intCast(usize, 12), mock.last_byte_count);
    expectEqualStrings("hello world!", mock.last_content[0..12 :0]);
}

test "self unregister on failed read" {
    var router = try Router.init(std.heap.page_allocator, 1, 100);
    defer router.deinit();

    const pipes = try os.pipe();
    defer os.close(pipes[0]);
    defer os.close(pipes[1]);

    const address = try Address.parseIp4("172.1.0.1", 0);

    var mock = MockPeer.init(pipes[0], address, true);
    try router.register(&mock.peer, 0);

    var written = try os.write(pipes[1], "hello world!");
    expectEqual(@intCast(usize, 12), written);

    try router.run();

    expectEqual(@intCast(i32, 1), mock.handle_count);
    expectEqual(@intCast(usize, 0), mock.last_byte_count);

    // Verify that the handler had unregistered itself.
    written = try os.write(pipes[1], "hello world!");
    expectEqual(@intCast(usize, 12), written);

    try router.run();

    // Expect unchanged values after self unregister.
    expectEqual(@intCast(i32, 1), mock.handle_count);
    expectEqual(@intCast(usize, 0), mock.last_byte_count);
}

test "no resources Router register" {
    var allocator = FailingAllocator.init(std.heap.page_allocator, 0);
    var router = try Router.init(&allocator.allocator, 1, 100);
    defer router.deinit();

    const address = try Address.parseIp4("172.1.0.1", 0);

    var mock = MockPeer.init(0, address, true);
    expectError(error.Resources, router.register(&mock.peer, 0));
}

test "no resources Router run" {
    var allocator = FailingAllocator.init(std.heap.page_allocator, 1);
    var router = try Router.init(&allocator.allocator, 1, 100);
    defer router.deinit();

    const pipes = try os.pipe();
    defer os.close(pipes[0]);
    defer os.close(pipes[1]);

    const address = try Address.parseIp4("172.1.0.1", 0);

    var mock = MockPeer.init(pipes[0], address, true);
    try router.register(&mock.peer, 0);

    expectError(error.Resources, router.run());
}
