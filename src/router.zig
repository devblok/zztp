// Copyright (c) 2020 Lukas Praninskas
//
// This software is released under the MIT License.
// https://opensource.org/licenses/MIT

const std = @import("std");
const os = std.os;
const assert = std.debug.assert;
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

pub const Error = error{ Interrupted, HandlerRead, Resources, NoHandler };

pub fn Handler(
    comptime Context: type,
    comptime handleFn: fn (context: Context) Error!void,
    comptime fdFn: fn (context: Context) i32,
) type {
    return struct {
        context: Context,

        const Self = @This();

        pub fn handle(self: Self) Error!void {
            return handleFn(self.context);
        }

        pub fn fd(self: Self) i32 {
            return fdFn(self.context);
        }
    };
}

/// Implements the packet handling mechanism.
pub fn Router(comptime HandlerT: type) type {
    return struct {
        epoll_fd: i32,
        epoll_timeout: i32,
        max_concurrent: u32,

        allocator: *Allocator,
        handlers_lock: std.Mutex,
        handlers: HandlerMap,

        const Self = @This();
        const HandlerMap = std.AutoHashMapUnmanaged(i32, HandlerT);

        /// Starts processing the incoming packets and writing them.
        pub fn run(self: *Self) Error!void {
            const events = self.allocator.alloc(os.epoll_event, self.max_concurrent) catch return error.Resources;
            defer self.allocator.free(events);

            try self.epollProc(events);
        }

        /// Register a handler so that it could start participating in the routing process.
        /// First, we insert the handler into the map, only later activating it via epoll.
        ///
        /// It accepts a handler and epoll flags that will influence the behaviour of signalling.
        /// Leaving flags to zero will result in a correct default behaviour.
        pub fn register(self: *Self, handler: HandlerT, flags: u32) !void {
            // We do not want to poll for write availability.
            assert(flags & os.EPOLLOUT == 0);

            const lock = self.handlers_lock.acquire();
            defer lock.release();

            try self.handlers.put(self.allocator, handler.fd(), handler);

            var ee = os.linux.epoll_event{
                .events = flags | os.EPOLLIN,
                .data = .{
                    .fd = handler.fd(),
                },
            };
            try os.epoll_ctl(self.epoll_fd, os.EPOLL_CTL_ADD, handler.fd(), &ee);
        }

        /// Removes the handler from routing. It's first disabled via epoll, to prevent
        /// the routing process from trying to access it. Only then it is removed from the map.
        pub fn unregister(self: *Self, handler: HandlerT) void {
            const lock = self.handlers_lock.acquire();
            defer lock.release();

            os.epoll_ctl(self.epoll_fd, os.EPOLL_CTL_DEL, handler.fd(), null) catch {};
            _ = self.handlers.remove(handler.fd());
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
            var handlerEntry: ?HandlerT = undefined;

            if (self.handlers_lock.tryAcquire()) |lock| {
                handlerEntry = self.handlers.get(event.data.fd);
                lock.release();
            }

            if (handlerEntry) |handler| {
                handler.handle() catch |err| {
                    switch (err) {
                        error.HandlerRead => self.unregister(handler),
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
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

const MockHandler = struct {
    socket: i32,
    ret_error: bool,
    handle_count: i32,
    last_byte_count: usize,
    last_content: [128:0]u8,

    const Self = @This();

    pub const HandlerType = Handler(*Self, handle, fd);

    pub fn init(socket: i32, ret_error: bool) Self {
        return .{
            .socket = socket,
            .ret_error = ret_error,
            .handle_count = 0,
            .last_byte_count = 0,
            .last_content = [_:0]u8{0} ** 128,
        };
    }

    pub fn handler(self: *Self) HandlerType {
        return .{ .context = self };
    }

    fn handle(self: *Self) Error!void {
        self.handle_count += 1;

        if (self.ret_error) {
            return error.HandlerRead;
        }

        self.last_byte_count = os.read(self.socket, self.last_content[0..]) catch |err| return error.HandlerRead;
    }

    fn fd(self: *Self) i32 {
        return self.socket;
    }
};

test "epoll" {
    var router = try Router(MockHandler.HandlerType).init(std.heap.page_allocator, 1, 100);
    defer router.deinit();

    const pipes = try os.pipe();
    defer os.close(pipes[0]);
    defer os.close(pipes[1]);

    var mock = MockHandler.init(pipes[0], false);
    try router.register(mock.handler(), 0);

    const written = try os.write(pipes[1], "hello world!");
    expectEqual(@intCast(usize, 12), written);

    try router.run();

    expectEqual(@intCast(i32, 1), mock.handle_count);
    expectEqual(@intCast(usize, 12), mock.last_byte_count);
    expectEqualStrings("hello world!", mock.last_content[0..12 :0]);
}

test "self unregister on failed read" {
    var router = try Router(MockHandler.HandlerType).init(std.heap.page_allocator, 1, 100);
    defer router.deinit();

    const pipes = try os.pipe();
    defer os.close(pipes[0]);
    defer os.close(pipes[1]);

    var mock = MockHandler.init(pipes[0], true);
    try router.register(mock.handler(), 0);

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
