// Copyright (c) 2020 Lukas Praninskas
//
// This software is released under the MIT License.
// https://opensource.org/licenses/MIT

const std = @import("std");
const os = std.os;

const Error = error{Read, Write};

pub fn Transport(
    comptime Context: type,
    comptime readFn: fn(context: Context, buf: []u8) io.Error!usize,
    comptime writeFn: fn(context: Context, bytes: []const u8) io.Error!usize,
    comptime closeFn: fn(context: Context) void,
) type {
    return struct {
        context: Context,

        const Self = @This();
        const Reader = io.Reader(*Self, Error, readFn);
        const Writer = io.Writer(*Self, Error, writeFn);

        pub fn reader(self: *Self) Reader {
            return .{ .context = self };
        }

        pub fn writer(self: *Self) Writer {
            return .{ context = self };
        }

        pub fn close(self: *Self) void {
            closefn(self);
        }
    };
}
