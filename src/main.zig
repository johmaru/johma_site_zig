const std = @import("std");
const http = @import("std").http;
const log = @import("std").log;
const Connection = @import("std").net.Server.Connection;
const Websocket = @import("std").http.WebSocket;
const Request = http.Server.Request;
const path = std.fs.path;
const c = @cImport(@cInclude("sqlite3.h"));

// 自分のライブラリ

const routing = @import("routing.zig");

const MAX_BUFFER_SIZE = 1024;
const DB_FILE_NAME = "database.sqlite";

pub fn main() !void {
    var allocator = std.heap.page_allocator;
    _ = routing.TypingItem.init(&allocator) catch |err| {
        log.err("Failed to initialize TypingItem: {s}", .{@errorName(err)});
        return err;
    };

    var exe_dir_path_buffer: [1024]u8 = undefined;

    const exe_dir_path = try std.fs.selfExeDirPath(&exe_dir_path_buffer);

    var db_path_buffer: [1024]u8 = undefined;
    const db_path = try std.fmt.bufPrint(&db_path_buffer, "{s}{c}{s}", .{exe_dir_path, path.sep, DB_FILE_NAME});

    const file_access_result = std.fs.accessAbsolute(db_path, .{});

    const db_exists: bool = if (file_access_result) |_| true else |err| switch (err) {
        error.FileNotFound => false,
        else => |e| return e,
    };

    if (!db_exists) {
        log.info("Database file not found ('{s}'). Assuming first launch. Initializing database...", .{db_path});
        // --- ここにデータベース作成と初期マイグレーションのコードを記述 ---
        // 例: SQLite C API を呼び出してデータベースを開き、CREATE TABLE を実行
        // const db = try openOrCreateDatabase(allocator, db_path);
        // defer db.close();
        // try runInitialMigration(db);

        var db_handle: ?*c.sqlite3 = null;
        var db_path_c_buffer: [1024]u8 = undefined;
        const db_path_c = try std.fmt.bufPrintZ(&db_path_c_buffer, "{s}", .{db_path});

        const rc_open = c.sqlite3_open(db_path_c.ptr, &db_handle);

        if (rc_open != c.SQLITE_OK) {
            const err_msg = if (db_handle) |h| c.sqlite3_errmsg(h) else c.sqlite3_errstr(rc_open);

            const err_msg_slice = std.mem.sliceTo(err_msg, 0);
            log.err("Failed to open/create database: {s}", .{err_msg_slice});
            if (db_handle) |_| {
                _ = c.sqlite3_close(db_handle);
            }
            return error.DbOpenFaild;
        }

        defer {
            if (db_handle) |h| {
                const rc_close = c.sqlite3_close(h);
            if (rc_close != c.SQLITE_OK) {
                const close_err_msg = c.sqlite3_errmsg(h);
                log.err("Failed to close database: {s}", .{close_err_msg});
            }
            }
        }

        log.info("Database opened successfully: {s}", .{db_path});

        const sql: [*:0]const u8 =
            \\CREATE TABLE IF NOT EXISTS users (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  name TEXT NOT NULL,
            \\  role TEXT NOT NULL DEFAULT 'User',
            \\  mail TEXT NOT NULL,
            \\  password TEXT NOT NULL
            \\);
        ;
        var exec_err_msg: [*c]u8 = null;
        const rc_exec = c.sqlite3_exec(db_handle, sql, null, null, &exec_err_msg);
        if (rc_exec != c.SQLITE_OK) {
            if (exec_err_msg) |msg| {
                log.err("Failed to execute SQL: {s}", .{exec_err_msg});
                c.sqlite3_free(msg);
            }

            std.fs.deleteDirAbsolute(db_path) catch |err| {
            log.err("Failed to execute SQL: {any}", .{err});

            };

            return error.DbMigrationFailed;
        }
        log.info("Database initialized successfully", .{});

    } else {
        log.info("Database file found ('{s}'). Skipping initialization.", .{db_path});
    }

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
