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

const Error = error{Interrupted};

pub const HandlerFn = fn () void;

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
    handlers: std.AutoHashMap(i32, Handler),

    const Self = @This();

    /// Starts processing the incoming packets and writing them.
    pub fn run(self: Self) !void {
        const events = try self.allocator.alloc(os.epoll_event, self.max_concurrent);
        defer self.allocator.free(events);

        try self.epoll_proc(events);
    }

    pub fn register(self: Self, handler: Handler) !void {
        const lock = self.handlers_lock.acquire();
        defer lock.release();

        try self.handlers.put(handler.fd, handler);
    }

    pub fn init(allocator: *Allocator, max_concurrent: u32, epoll_timeout: i32) !Self {
        return Self{
            .epoll_fd = try os.epoll_create1(0),
            .epoll_timeout = epoll_timeout,
            .max_concurrent = max_concurrent,
            .allocator = allocator,
            .handlers = std.AutoHashMap(i32, Handler).init(allocator),
            .handlers_lock = std.Mutex{},
        };
    }

    pub fn deinit(self: Self) void {
        os.close(self.epoll_fd);
        self.handlers.deinit();
    }

    fn epoll_proc(self: Self, events: []os.epoll_event) Error!void {
        var ret: usize = 0;
        while (ret >= 0) : (ret = os.epoll_wait(self.epoll_fd, events.ptr, events.len, self.epoll_timeout)) {
            for (events[0..ret]) |event| {
                const lock = self.handlers_lock.acquire();

                if (self.handlers.get(event.fd)) |handler| {
                    handler.func();
                }

                lock.release();
            }
        }
        return;
    }
};

fn print() !void {
    std.debug.print("epoll handled\n", .{});
}

test "epoll detection" {
    var router = Router.init(std.heap.page_allocator, 1, 100);
    const pipes = try os.pipe();

    try router.register(.{
        .fd = pipes[1],
        .func = print,
    });
}
