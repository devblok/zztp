// Copyright (c) 2020 Lukas Praninskas
//
// This software is released under the MIT License.
// https://opensource.org/licenses/MIT

const std = @import("std");
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

/// Implements the packet handling mechanism.
pub const Router = struct {
    allocator: *Allocator,
    sockets: std.ArrayList(i32),

    const Self = @This();

    /// Starts processing the incoming packets and writing them.
    pub fn run(self: Self) !void {
        return;
    }

    pub fn init(allocator: *Allocator) !Self {
        return Self{
            .allocator = allocator,
            .sockets = std.ArrayList(i32).init(allocator),
        };
    }

    pub fn deinit(self: Self) void {
        self.sockets.deinit();
    }
};
