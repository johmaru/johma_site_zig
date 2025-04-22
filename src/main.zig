const std = @import("std");
const http = @import("std").http;
const log = @import("std").log;
const Connection = @import("std").net.Server.Connection;
const Websocket = @import("std").http.WebSocket;
const Request = http.Server.Request;

// 自分のライブラリ

const routing = @import("routing.zig");

const MAX_BUFFER_SIZE = 1024;

pub fn main() !void {
    var allocator = std.heap.page_allocator;
    _ = routing.TypingItem.init(&allocator) catch |err| {
        log.err("Failed to initialize TypingItem: {s}", .{@errorName(err)});
        return err;
    };

    server_run() catch |err| {
        log.err("Server error: {s}", .{@errorName(err)});
        return err;
    };
    log.info("Server stopped", .{});
}

pub fn server_run() !void {
    const addr = try std.net.Address.parseIp("0.0.0.0", 8080);
    var server = try std.net.Address.listen(addr, .{.reuse_address = true});
    defer server.deinit();

    
    log.info("Server listening on {any}", .{addr});

    while (true) {
        const conn = server.accept() catch |err| {
           log.err("failed to accept connection: {s}", .{@errorName(err)});
           continue;
        };
        _ = std.Thread.spawn(.{},accept, .{conn}) catch |err| {
            log.err("failed to spawn thread: {s}", .{@errorName(err)});
            conn.stream.close();
            continue;
        };
    }

    
}

fn accept(conn: Connection) !void {
    defer conn.stream.close();

    log.info("Accepted connection from {any}", .{conn.address});

    var reader_buf: [MAX_BUFFER_SIZE]u8 = undefined;
    var server = http.Server.init(conn, &reader_buf);
    while (server.state == .ready) {
        var request = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => return err,
        };

        try serveHttp(&request, conn);
    
    }
}

fn serveHttp(request: *Request,conn: Connection) !void {
    routing.route(request, conn) catch |err| {
        if (err == error.HttpConnectionClosing) return;
        if (err == error.ConnectionResetByPeer and std.mem.eql(u8, request.head.target, "/ws/typing")) return;
        log.err("Error in routing ({s}): {s}", .{request.head.target, @errorName(err)});
        _ = request.respond("500 Internal Server Error", .{ .status = .internal_server_error }) catch {};
    };
}


fn serveWebSocket(ws: *Websocket) !void {
    try ws.writeMessage("Message from zig", .text);
    while (true) {
        const msg = try ws.readSmallMessage();
        try ws.writeMessage(msg.data, msg.opcode);
    }
}
