const std = @import("std");
const os = std.os;
const net = std.net;
const printf = std.debug.print;
const Address = std.net.Address;

pub fn main() !void {
    const allocator = &std.heap.page_allocator;

    const sock = try os.socket(os.AF_INET, os.SOCK_STREAM, 0);
    defer os.close(sock);

    var server = net.StreamServer.init(.{});
    defer server.deinit();

    const address = try Address.parseIp4("0.0.0.0", 8080);
    try server.listen(address);

    var addr: os.sockaddr = undefined;
    var addr_siz: u32 = undefined;

    while (true) {
        const conn = try server.accept();
        printf("Connected {}\n", .{});
        var keepReading: bool = true;
        while (keepReading) {
            var buffer: [4096]u8 = undefined;
            const numBytes = try conn.file.read(buffer[0..]);
            printf("{} bytes read: {}", .{ numBytes, buffer });
        }
        conn.file.close();
    }
}
