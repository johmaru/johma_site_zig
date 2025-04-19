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
    server_run() catch |err| {
        log.err("Server error: {s}", .{@errorName(err)});
        return err;
    };
    log.info("Server stopped", .{});
}

pub fn server_run() !void {
    const addr = try std.net.Address.parseIp("127.0.0.1", 8080);
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

        var ws: Websocket = undefined;
        var send_buf: [MAX_BUFFER_SIZE]u8 = undefined;
        var recv_buf: [MAX_BUFFER_SIZE]u8 align(4) = undefined;

        if (try ws.init(&request, &send_buf, &recv_buf)){
            serveWebSocket(&ws) catch |err| switch (err) {
                error.ConnectionClose => {
                    log.info("Client({any}) closed!", .{conn.address});
                    break;
                },
                else => return err,
            };
        } else {
            try serveHttp(&request, conn);
        }
    }
}

fn serveHttp(request: *Request,conn: Connection) !void {
    routing.route(request, conn) catch |err| {
        if (err == error.HttpConnectionClosing) return;
        log.err("Error in routing: {s}", .{@errorName(err)});
        return err;
    };
}


fn serveWebSocket(ws: *Websocket) !void {
    try ws.writeMessage("Message from zig", .text);
    while (true) {
        const msg = try ws.readSmallMessage();
        try ws.writeMessage(msg.data, msg.opcode);
    }
}
