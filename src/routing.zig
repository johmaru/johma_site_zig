const std = @import("std");
const http = std.http;
const log = std.log;
const Connection = std.net.Server.Connection;
const Websocket = std.http.WebSocket;
const Request = http.Server.Request;



pub const TypingItem = struct {

    const HTML_TYPE_1 = "ようこそ、私のサイトへ";
    const HTML_TYPE_2 = "作者 Johmaru";
    allocator: *std.mem.Allocator = undefined,

    var map = std.HashMap([]const u8, []const u8, std.hash_map.StringContext, std.hash_map.default_max_load_percentage,).init(std.heap.page_allocator);

    const Self = @This();

    pub fn init(allocator: *std.mem.Allocator) !TypingItem {

        map.put("/ws/typing", HTML_TYPE_1) catch |err| {
            std.debug.print("Failed to put value in map: {s}\n", .{@errorName(err)});
            return err;
        };
        map.put("ws/typing2", HTML_TYPE_2) catch |err| {
            std.debug.print("Failed to put value in map: {s}\n", .{@errorName(err)});
            return err;
        };


        return TypingItem{
            .allocator = allocator
        };
    }

    pub fn deinit(self: *Self) void {
        map.deinit();
        self.allocator.destroy(self);
    }
    
};

// ルーティング関数
pub fn route(request: *Request,conn: Connection) !void {
    const allocator = std.heap.page_allocator;

    var buf : [256]u8 = undefined;
    var uri = request.head.target;

    // 一番最初にwebsocketを探索
    if (try websocket_handler(request)) return;


    // 次にapiを探索
    if (try api(uri, conn)) {
        return;
    }

    // テーマはapiの後に探索
    if (std.mem.startsWith(u8, uri, "/toggle-theme")) {
        try toggle_theme(request);
        return;
    }

    if (std.mem.indexOfScalar(u8, uri, '?')) |i| {
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

    // 対応拡張子 html css js
    // それ以外はapplication/octet-stream
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


    // 簡易なテンプレートエンジン
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

// プレースホルダを置き換える関数
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

// APIのルーティング
fn api(uri:[]const u8, conn: Connection) !bool {

    if (std.mem.startsWith(u8, uri, "/api/typing1")) {
        const string_type = TypingItem.HTML_TYPE_1;
        try write_to_html(string_type, conn);
        return true;
    } else if (std.mem.startsWith(u8, uri, "/api/typing2")) {
        const string_type = TypingItem.HTML_TYPE_2;
        try write_to_html(string_type, conn);
        return true;
    }
    return false;
}

// ヘッダの値を取得する関数
fn getHeaderValue(req: *Request, name: []const u8) ?[]const u8 {
    var it = req.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) {
            return h.value;
        }
    }
    return null;
}

fn toggle_theme(req: *Request) !void {
    const dark_cookie = "theme=dark";
    const light_cookie = "theme=light";

    var want_dark = true;
    if (getHeaderValue(req, "cookie")) |cookie_line| {
        if (std.mem.indexOf(u8, cookie_line, dark_cookie) != null) {
            want_dark = false;
        }
    }

    const cookie_val = if (want_dark) dark_cookie else light_cookie;
    var buf: [128]u8 = undefined;
    const set_cookie = try std.fmt.bufPrint(
        &buf,
        "{s}; Path=/; Max-Age=31536000",
        .{ cookie_val },
    );
    try req.respond("", .{
        .status = .no_content,
        .extra_headers = &[_]http.Header{
            .{ .name = "Set-Cookie", .value = set_cookie },
            .{ .name = "HX-Refresh", .value = "true" },
        },
    });
}

fn websocket_handler(req: *Request) !bool {
    var iter = TypingItem.map.iterator();
    while (iter.next()) |item| {

        if (std.mem.eql(u8, req.head.target, item.key_ptr.*)) {
            var send_buf: [4096]u8 = undefined;
            var recv_buf: [4096]u8 align(4) = undefined;

            var ws: Websocket = undefined;


            const upgraded = try Websocket.init(&ws, req, &send_buf, &recv_buf);
            if (!upgraded) return false;
            
            var it = std.unicode.Utf8Iterator{ .bytes = item.value_ptr.*, .i = 0 };
            var prev: usize = 0;
            while (it.nextCodepoint()) |_| {
                try ws.writeMessage(item.value_ptr.*[prev..it.i], .text);
                prev = it.i;
                std.time.sleep(300 * std.time.ns_per_ms);
            }
            _ = ws.writeMessage(&.{}, .connection_close) catch {};
            
            return true;
        }
    }
    return false;
}
 
// タイピングの文字列をHTMLに書き込む関数(SSE)
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