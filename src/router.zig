// Copyright (c) 2020 Lukas Praninskas
//
// This software is released under the MIT License.
// https://opensource.org/licenses/MIT

const std = @import("std");
const os = std.os;
const Allocator = std.mem.Allocator;

/// The definition on an IP packet header.
pub const PacketHeader = packed struct {
    ver_and_ihl: u8,
    tos: u8,
    length: u16,
    identification: u16,
    flags_and_frag_offset: u16,
    ttl: u8,
    proto: u8,
    crc: u16,
    source: u32,
    destination: u32,
    options: u32,
};

// What a router should do:
// 1. Poll and wait for a file descriptor to be ready
// 2. Read the available data to buffer
// 3. Interpret the IP packet header
// 4. Assert the correct destination of the arriving packet
// 5. Pass it to the transport that will take care of sending it
// 6. Repeat.
// Misc. Allow insertion and deletion of clients from the loop

const Error = error{ Interrupted, HandlerRead, Resources };

pub const HandlerFn = fn (fd: i32) Error!void;

pub const Handler = struct {
    fd: i32,
    func: HandlerFn,
};

/// Implements the packet handling mechanism.
pub const Router = struct {
    epoll_fd: i32,
    epoll_timeout: i32,
    max_concurrent: u32,

    allocator: *Allocator,
    handlers_lock: std.Mutex,
    handlers: HandlerMap,

    const Self = @This();
    const HandlerMap = std.AutoHashMapUnmanaged(i32, Handler);

    /// Starts processing the incoming packets and writing them.
    pub fn run(self: *Self) Error!void {
        const events = self.allocator.alloc(os.epoll_event, self.max_concurrent) catch return error.Resources;
        defer self.allocator.free(events);

        self.epollProc(events);
    }

    pub fn register(self: *Self, handler: Handler) !void {
        const lock = self.handlers_lock.acquire();
        defer lock.release();

        try self.handlers.put(self.allocator, handler.fd, handler);
    }

    pub fn unregister(self: *Self, handler: Handler) void {
        const lock = self.handlers_lock.acquire();
        defer lock.release();

        _ = self.handlers.remove(handler.fd);
    }

    pub fn init(allocator: *Allocator, max_concurrent: u32, epoll_timeout: i32) !Self {
        return Self{
            .epoll_fd = try os.epoll_create1(0),
            .epoll_timeout = epoll_timeout,
            .max_concurrent = max_concurrent,
            .allocator = allocator,
            .handlers = HandlerMap.init(allocator),
            .handlers_lock = std.Mutex{},
        };
    }

    pub fn deinit(self: *Self) void {
        os.close(self.epoll_fd);
        self.handlers.deinit(self.allocator);
    }

    fn epollProc(self: *Self, e: []os.epoll_event) void {
        var ret: usize = 0;
        while (ret > 0) : (ret = os.epoll_wait(self.epoll_fd, e, self.epoll_timeout)) {
            for (e[0..ret]) |event| {
                self.execHandler(event);
            }
        }
    }

    fn execHandler(self: *Self, event: os.epoll_event) void {
        var handlerEntry: ?Handler = undefined;

        if (self.handlers_lock.tryAcquire()) |lock| {
            handlerEntry = self.handlers.get(event.data.fd);
            lock.release();
        }

        if (handlerEntry) |handler| {
            handler.func(event.data.fd) catch |err| {
                switch (err) {
                    error.HandlerRead => self.unregister(handler),
                    error.Interrupted => unreachable,
                    error.Resources => unreachable,
                }
            };
        }
    }
};

const expect = std.testing.expect;

fn assertHandler(fd: i32) Error!void {
    var buf = [_]u8{0} ** 16;
    const count = os.read(fd, buf[0..]) catch |err| return error.HandlerRead;
    std.debug.print("epoll handled for {}: {} bytes read\nraw: {}\n", .{ fd, count, buf });
}

test "epoll" {
    var router = try Router.init(std.heap.page_allocator, 1, 100);
    defer router.deinit();

    const pipes = try os.pipe();
    defer os.close(pipes[0]);
    defer os.close(pipes[1]);

    try router.register(.{
        .fd = pipes[0],
        .func = assertHandler,
    });

    var run = async router.run();

    const written = try os.write(pipes[1], "hello world!");
    expect(written == 12);

    try await run;
}

test "self unregister on failed read" {
    var router = try Router.init(std.heap.page_allocator, 1, 100);
    defer router.deinit();

    const pipes = try os.pipe();
    defer os.close(pipes[0]);
    defer os.close(pipes[1]);

    try router.register(.{
        .fd = 987,
        .func = assertHandler,
    });

    // TODO complete test
}
