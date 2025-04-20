const std = @import("std");
const http = @import("std").http;
const log = @import("std").log;
const Connection = @import("std").net.Server.Connection;
const Websocket = @import("std").http.WebSocket;
const Request = http.Server.Request;

const HTML_TYPE_1 = "ようこそ、私のサイトへ";
const HTML_TYPE_2 = "Johmaru";

pub fn route(request: *Request,conn: Connection) !void {
    const allocator = std.heap.page_allocator;

    var buf : [256]u8 = undefined;
    var uri = request.head.target;

    if (try api(uri, conn)) {
        return;
    }

    

    if (std.mem.indexOfScalar(u8, uri, '?')) |i| {
        // Remove query string
        uri = uri[0..i];
    }

    const html_extension = std.fs.path.extension(uri);

    const full_path = std.fmt.allocPrint(allocator, "src/html{s}", .{uri}) catch |e| {
        std.debug.print("Failed to allocate memory: {any}\n", .{e});
        return e;
    };
    defer allocator.free(full_path);

    const local_path = if (std.mem.eql(u8, uri, "/")) "src/html/index.html"
    else if (std.mem.eql(u8, html_extension, ".html")) full_path
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

    var processed_cotents = std.ArrayList(u8).fromOwnedSlice(allocator, contents);
    defer processed_cotents.deinit();

    if (std.mem.startsWith(u8, content_type, "text/html")) {
        try replacePlaceholder(&processed_cotents, "{{HEAD}}", "src/html/_head.html", allocator);
        try replacePlaceholder(&processed_cotents, "{{HEADER}}", "src/html/_header.html", allocator);
    }

    try request.respond(
        processed_cotents.items,
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

fn replacePlaceholder(
    list: *std.ArrayList(u8),
    placeholder: []const u8,
    path: []const u8,
    allocator: std.mem.Allocator,
) !void {
    if (std.mem.indexOf(u8, list.items, placeholder)) |pos|{
        const f = try std.fs.cwd().openFile(path, .{});
        defer f.close();
        const tpl = try f.readToEndAlloc(allocator, std.math.maxInt(usize));
        defer allocator.free(tpl);

        try list.replaceRange(pos, placeholder.len, tpl);
    }
}

fn api(uri:[]const u8, conn: Connection) !bool {

    if (std.mem.startsWith(u8, uri, "/api/typing1")) {
        const string_type = HTML_TYPE_1;
        try write_to_html(string_type, conn);
        return true;
    } else if (std.mem.startsWith(u8, uri, "/api/typing2")) {
        const string_type = HTML_TYPE_2;
        try write_to_html(string_type, conn);
        return true;
    }
    return false;
}

fn write_to_html(string_type: []const u8, conn: Connection) !void {
    const w = conn.stream.writer();
    try w.writeAll(
            "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: text/event-stream; charset=utf-8\r\n" ++
            "Cache-Control: no-cache\r\n" ++
            "Connection: keep-alive\r\n" ++
            "\r\n",
            );

            {
                var it = std.unicode.Utf8Iterator{ .bytes = string_type, .i = 0 };

                while (it.nextCodepoint()) |_| { 
                    w.writeAll("event: message\ndata: ") catch |err| {
                        if (err == error.ConnectionResetByPeer) return;
                        return err;
                    };
                    w.writeAll(string_type[0 .. it.i]) catch |err| {
                        if (err == error.ConnectionResetByPeer) return;
                        return err;
                    };
                    w.writeAll("\n\n") catch |err| {
                        if (err == error.ConnectionResetByPeer) return;
                        return err;
                    };
                    std.time.sleep(300 * std.time.ns_per_ms);
                }

                while (true) {
                    _ = w.writeAll(": keep-alive\n\n") catch |e| {
                    if (e == error.ConnectionResetByPeer) return;
                    return e;
                    };
                    std.time.sleep(30 * std.time.ns_per_s);
                }
            }        
}