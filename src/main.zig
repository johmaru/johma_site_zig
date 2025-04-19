const std = @import("std");
const http = @import("std").http;
const log = @import("std").log;
const Connection = @import("std").net.Server.Connection;
const Websocket = @import("std").http.WebSocket;
const Request = http.Server.Request;

const MAX_BUFFER_SIZE = 1024;
const HTML_TYPE_1 = "ようこそ、私のサイトへ";

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
    const allocator = std.heap.page_allocator;

    var buf : [256]u8 = undefined;
    var uri = request.head.target;

    if (std.mem.startsWith(u8, uri, "/api/typing")) {
        const w = conn.stream.writer();
        try w.writeAll(
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: text/event-stream; charset=utf-8\r\n" ++
        "Cache-Control: no-cache\r\n" ++
        "Connection: keep-alive\r\n" ++
        "\r\n",
        );

        {
            var it = std.unicode.Utf8Iterator{ .bytes = HTML_TYPE_1, .i = 0 };

            while (it.nextCodepoint()) |_| { 
                const slice = HTML_TYPE_1[0 .. it.i];
                const res = w.writeAll("event: message\ndata: ") catch |e| {
                    if (e == error.ConnectionResetByPeer) return;
                    return e;
                };
                _ = res;

                try w.writeAll(slice);
                try w.writeAll("\n\n");
                std.time.sleep(1 * std.time.ns_per_s);
            }

            _ = w.writeAll("event: end\ndata: done\n\n") catch {};
            while (true) {
                try w.writeAll(": keep-alive\n\n");
                std.time.sleep(30 * std.time.ns_per_s);
            }
        }
    }

    if (std.mem.indexOfScalar(u8, uri, '?')) |i| {
        // Remove query string
        uri = uri[0..i];
    }

    const local_path = if (std.mem.eql(u8, uri, "/") or
        std.mem.eql(u8, uri, "/index.html"))
        "src/html/index.html"
        else blk: {
            const rel = uri[1..];
            const p = try std.fmt.bufPrint(&buf, "src/{s}", .{rel});
            break :blk p;
        };    

    const ext = std.fs.path.extension(local_path);
    const content_type =
        if (std.mem.eql(u8, ext, ".css"))
            "text/css; charset=utf-8"
        else if (std.mem.eql(u8, ext, ".js"))
            "text/javascript; charset=utf-8"
        else if (std.mem.eql(u8, ext, ".html"))
            "text/html; charset=utf-8"
        else
            "application/octet-stream";

    const file = std.fs.cwd().openFile(local_path, .{}) catch |e| switch (e) {
        error.FileNotFound => {
            std.debug.print("File not found: {s}\n", .{local_path});

            try request.respond("404 Not Found", .{
                .status = .not_found,
                .extra_headers = &.{
                    .{
                        .name = "Content-Type",
                        .value = "text/plain; charset=utf-8",
                    }
                }
            });
            return;
        },
        else => return e,
    };
    defer file.close();
    const contents = try file.readToEndAlloc(allocator, std.math.maxInt(usize));

    try request.respond(
        contents,
        .{
            .extra_headers = &[_]http.Header{
                http.Header{
                    .name = "Content-Type",
                    .value = content_type,
                },
            },
        },
    );
}


fn serveWebSocket(ws: *Websocket) !void {
    try ws.writeMessage("Message from zig", .text);
    while (true) {
        const msg = try ws.readSmallMessage();
        try ws.writeMessage(msg.data, msg.opcode);
    }
}
