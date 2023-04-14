const std = @import("std");

/// Global allocator
const allocator = std.heap.c_allocator;

/// A store of string-to-string pairs
const Store = std.StringHashMap([]const u8);

/// A global instance of the store
var store: Store = undefined;

/// Size of the buffer (in bytes) for read operations
const BUFSIZE: usize = 1000;

/// A header for the responses
const HEADER =
    "HTTP/1.1 200 OK\r\n" ++
    "Connection: close\r\n" ++
    "Content-Type: text/plain\r\n" ++
    "\r\n";

const stderr = std.io.getStdErr().writer();
const stdout = std.io.getStdOut().writer();

// ANSI escape codes
const red = "\u{001b}[1;31m";
const green = "\u{001b}[1;32m";
const yellow = "\u{001b}[1;33m";
const cyan = "\u{001b}[1;36m";
const white = "\u{001b}[1;37m";
const reset = "\u{001b}[m";

// Override the default logger
pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const level_txt = comptime switch (message_level) {
        .err => red ++ "ERROR" ++ reset,
        .warn => yellow ++ "WARNING" ++ reset,
        .info => white ++ "INFO" ++ reset,
        .debug => cyan ++ "DEBUG" ++ reset,
    };
    const prefix = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
    std.debug.getStderrMutex().lock();
    defer std.debug.getStderrMutex().unlock();
    nosuspend stderr.print(level_txt ++ prefix ++ format ++ "\n", args) catch return;
}

fn cleanup() void {
    var store_iterator = store.iterator();
    while (store_iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        allocator.free(key);
        allocator.free(value);
    }
    store.deinit();
}

fn handleInterruption(_: c_int) callconv(.C) void {
    stderr.print("\r", .{}) catch {};
    std.log.info("Exiting...", .{});
    cleanup();
    std.process.exit(0);
}

fn handleSet(client_writer: anytype, route: []const u8) !void {
    const pairs = route[4..];
    var pairs_iterator = std.mem.tokenize(u8, pairs, "?");

    try client_writer.print(HEADER, .{});

    var count: usize = 0;

    while (pairs_iterator.next()) |pair| {
        var key_value_iterator = std.mem.tokenize(u8, pair, "=");

        const key = key_value_iterator.next() orelse continue;
        const value = key_value_iterator.next() orelse continue;

        const entry = try store.getOrPut(key);
        if (entry.found_existing) {
            // Free the existing value
            allocator.free(entry.value_ptr.*);
        } else {
            // Allocate the key
            const allocated_key = try allocator.alloc(u8, key.len);
            std.mem.copy(u8, allocated_key, key);
            entry.key_ptr.* = allocated_key;
        }

        const allocated_value = try allocator.alloc(u8, value.len);
        std.mem.copy(u8, allocated_value, value);
        entry.value_ptr.* = allocated_value;

        try client_writer.print(
            "The value of the key \"{s}\" has been set to \"{s}\".\n",
            .{ key, value },
        );

        count += 1;
    }

    if (count == 0) {
        try client_writer.print(
            "No correct key-value pairs have been provided.",
            .{},
        );
    }
}

fn handleGet(client_writer: anytype, route: []const u8) !void {
    const pairs = route[4..];
    var pairs_iterator = std.mem.tokenize(u8, pairs, "?");

    try client_writer.print(HEADER, .{});

    var count: usize = 0;

    while (pairs_iterator.next()) |pair| {
        var option_key_iterator = std.mem.tokenize(u8, pair, "=");

        const option = option_key_iterator.next() orelse continue;
        if (!std.mem.eql(u8, option, "key")) continue;

        const key = option_key_iterator.next() orelse continue;

        if (store.get(key)) |value| {
            try client_writer.print(
                "The key \"{s}\" has the value \"{s}\".\n",
                .{ key, value },
            );
        } else {
            try client_writer.print(
                "The key \"{s}\" doesn't have any value.\n",
                .{key},
            );
        }

        count += 1;
    }

    if (count == 0) {
        try client_writer.print(
            "No keys have been requested.",
            .{},
        );
    }
}

fn formatStore() ![]const u8 {
    var string: []const u8 = "";
    var store_iterator = store.iterator();
    while (store_iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        const row = try std.fmt.allocPrint(allocator, "{s}: {s}\n", .{ key, value });
        const new_string = try std.mem.concat(allocator, u8, &.{ string, row });
        allocator.free(string);
        allocator.free(row);
        string = new_string;
    }
    return string;
}

pub fn main() !void {
    // Exit gracefully on interrupt
    const act = std.os.Sigaction{
        .handler = .{ .handler = handleInterruption },
        .mask = std.os.empty_sigset,
        .flags = 0,
    };
    try std.os.sigaction(std.os.SIG.INT, &act, null);

    store = Store.init(allocator);

    const address = try std.net.Address.resolveIp("127.0.0.1", 4000);

    var server = std.net.StreamServer.init(.{
        // Allow the reuse of the exact combination of source address and port
        .reuse_address = true,
    });
    defer server.deinit();

    try server.listen(address);

    var buffer: [BUFSIZE]u8 = undefined;

    while (true) {
        std.log.info("Waiting for the connection...", .{});

        var client = try server.accept();
        const client_reader = client.stream.reader();
        const client_writer = client.stream.writer();
        defer client.stream.close();

        std.log.info("Connection established!", .{});

        const n = try client_reader.read(&buffer);
        const message = buffer[0..n];

        var header_iterator = std.mem.tokenize(u8, message, " ");

        const request_method = header_iterator.next() orelse continue;
        _ = request_method;

        const route = header_iterator.next() orelse continue;
        if (std.mem.startsWith(u8, route, "/set")) {
            try handleSet(client_writer, route);
        } else if (std.mem.startsWith(u8, route, "/get")) {
            try handleGet(client_writer, route);
        } else {
            try client_writer.print(HEADER, .{});
            try client_writer.print("{s}", .{
                \\Hello there!
                \\
                \\This little server responds to the following routes:
                \\- `/set?somekey=somevalue`: Store the passed key and value in memory
                \\- `/get?key=somekey`: Return the value stored at `somekey`
                \\
                \\For any other route you will see this message.
                \\
            });
        }

        const file = try std.fs.cwd().createFile("store", .{});
        defer file.close();

        const file_writer = file.writer();
        const store_string = try formatStore();
        try file_writer.print("{s}", .{store_string});
        allocator.free(store_string);

        std.log.info("Connection closed!\n", .{});
    }
}
