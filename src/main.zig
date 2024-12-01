const std = @import("std");
const xxhash = @import("xxhash.zig");
const windows = @import("windows.zig");
const mapping = @import("mapping.zig");
const hashes = @import("hashes.zig");
const compress = @import("compress.zig");
const wad = @import("wad.zig");
const fs = std.fs;
const io = std.io;
const mem = std.mem;
const zstd = std.compress.zstd;
const assert = std.debug.assert;
const native_endian = @import("builtin").target.cpu.arch.endian();
const time = std.time;

pub fn main_generate_hashes() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .verbose_log = true }){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator(); // todo: use  c_allocator on unsafe release modes

    var client = std.http.Client{
        .allocator = allocator,
    };
    defer client.deinit();

    const uri = try std.Uri.parse("http://raw.communitydragon.org/data/hashes/lol/hashes.game.txt"); // http so there would not be any tls overhead
    var server_header_buffer: [16 * 1024]u8 = undefined;

    var req = try client.open(.GET, uri, .{
        .server_header_buffer = &server_header_buffer,
        .keep_alive = false,
    });
    defer req.deinit();

    try req.send();

    try req.finish();
    try req.wait();

    if (req.response.status != .ok) {
        //req.response.skip = true;
        //assert(try req.transferRead(&.{}) == 0);

        return error.InvalidStatusCode;
    }

    var line_buf: [4 * 1024]u8 = undefined;
    var fbs = io.fixedBufferStream(&line_buf);

    const writer = fbs.writer();

    var buf: [std.http.Client.Connection.buffer_size]u8 = undefined; // we prob can use connections buffer, like fill cmds

    var start: usize = 0;
    var end: usize = 0;

    const out_file = try fs.cwd().createFile(".hashes", .{}); // mb maping would prob be better, cuz on falure we would not have corrupted .hashes file
    defer out_file.close();

    var game_hashes = hashes.Compressor.init(allocator);
    defer game_hashes.deinit();

    while (true) { // zig implemintation is rly rly slow
        if (mem.indexOfScalar(u8, buf[start..end], '\n')) |pos| {
            try writer.writeAll(buf[start .. start + pos]);
            start += pos + 1;

            {
                const line = line_buf[0..fbs.pos];
                assert(line.len > 17);
                assert(line[16] == ' ');

                const hash = try fastHexParse(u64, line[0..16]);
                const file = line[17..];

                try game_hashes.update(hash, file);
            }
            fbs.pos = 0;

            continue;
        }
        try writer.writeAll(buf[start..end]);

        const amt = try req.read(buf[0..]);
        if (amt == 0) break; //return error.EndOfStream;

        start = 0;
        end = amt;
    }

    std.debug.print("finalizing\n", .{});

    const final = try hashes.final();

    std.debug.print("writting to file: {d}\n", .{final.len});
    try out_file.writeAll(final);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .verbose_log = true }){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator(); // todo: use  c_allocator on unsafe release modes

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next().?;

    const src = args.next() orelse return error.ArgumentSrcFileMissing;
    const dst = args.next() orelse return error.ArgumentDstDirMissing;

    var out_dir = try fs.cwd().makeOpenPath(dst, .{});
    defer out_dir.close();

    const hashes_file = try fs.cwd().openFile(".hashes", .{});
    defer hashes_file.close();

    const hashes_mapping = try mapping.mapFile(hashes_file);
    defer hashes_mapping.unmap();

    const game_hashes = hashes.decompressor(hashes_mapping.view);

    const file = try fs.cwd().openFile(src, .{});
    defer file.close();

    const file_mapping = try mapping.mapFile(file);
    defer file_mapping.unmap();

    var file_stream = io.fixedBufferStream(file_mapping.view);

    var window_buf: [1 << 17]u8 = undefined;
    var out_buf: [1 << 17]u8 = undefined;

    var iter = try wad.iterator(allocator, file_stream.reader(), file_stream.seekableStream(), &window_buf);
    defer iter.deinit();

    var total_path_timer: u64 = 0;
    var avg_path_timer: u64 = 0;

    var total_decompression_timer: u64 = 0;
    var avg_decompression_timer: u64 = 0;

    var total_write_timer: u64 = 0;
    var avg_write_timer: u64 = 0;

    // We need to optimize this solution is single thread enviroment first, then we can add multi threading and async io (idk how async io would work here, prob would be even slower)
    while (try iter.next()) |entry| {
        var path_timer = try std.time.Timer.start();
        const path = game_hashes.get(entry.hash).?;
        const path_time = path_timer.read();

        total_path_timer += path_time;
        avg_path_timer += path_time / iter.entries_len;

        if (fs.path.dirname(path)) |dir| {
            try out_dir.makePath(dir);
        }

        const out_file = out_dir.createFile(path, .{}) catch |err| switch (err) { // bench
            error.BadPathName => { // add like _invalid path
                std.debug.print("warn: invalid path:  {s}.\n", .{path});
                continue;
            },
            else => return err,
        };
        defer out_file.close();

        //std.debug.print("writting: {s}\n", .{path});

        // we should bench like creating mmap for a whole file, cuz we know out size
        switch (entry.decompressor) {
            .none => |stream| {
                var len: usize = 0;
                while (entry.decompressed_len > len) {
                    var decompression_timer = try std.time.Timer.start();
                    const amt = try stream.readAll(out_buf[0..@min(out_buf.len, entry.decompressed_len - len)]);
                    const decompression_time = decompression_timer.read();

                    total_decompression_timer += decompression_time;
                    avg_decompression_timer += decompression_time / iter.entries_len;

                    len += amt;

                    var write_timer = try std.time.Timer.start();
                    try out_file.writeAll(out_buf[0..amt]);
                    const write_time = write_timer.read();

                    total_write_timer += write_time;
                    avg_write_timer += write_time / iter.entries_len;
                }

                assert(len == entry.decompressed_len);
            },
            .zstd => |zstd_stream| {
                var len: usize = 0;
                while (entry.decompressed_len > len) { // cuz if we hit zstd_multi we will have multiple blocks
                    var decompression_timer = try std.time.Timer.start();
                    const chunk_len = try zstd_stream.read(&out_buf);
                    const decompression_time = decompression_timer.read();

                    total_decompression_timer += decompression_time;
                    avg_decompression_timer += decompression_time / iter.entries_len;

                    len += chunk_len;

                    var write_timer = try std.time.Timer.start();
                    try out_file.writeAll(out_buf[0..chunk_len]);
                    const write_time = write_timer.read();

                    total_write_timer += write_time;
                    avg_write_timer += write_time / iter.entries_len;
                }
                assert(len == entry.decompressed_len);
            },
        }
    }

    // all done on Aatrox.wad.client

    // damm this is fast ~20ms
    std.debug.print("total time spent getting paths: {d}ms, avg: {d}ms\n", .{ total_path_timer / time.ns_per_ms, avg_path_timer / time.ns_per_ms });
    // avg is ~2ms  and it is not bad, but this is the most time spent so it would be nice to have it near zero atleast 1ms
    std.debug.print("total time spent decompressing: {d}ms, avg: {d}ms\n", .{ total_decompression_timer / time.ns_per_ms, avg_decompression_timer / time.ns_per_ms });
    // 551ms rly no bad, but mmap prob could make it even less
    std.debug.print("total time spent writing to file: {d}ms, avg: {d}ms\n", .{ total_write_timer / time.ns_per_ms, avg_write_timer / time.ns_per_ms });
}

fn fastHexParse(comptime T: type, buf: []const u8) !u64 { // we can simd, but idk if its needed
    var result: T = 0;

    for (buf) |ch| {
        var mask: T = undefined;

        if (ch >= '0' and ch <= '9') {
            mask = ch - '0';
        } else if (ch >= 'a' and ch <= 'f') {
            mask = ch - 'a' + 10;
        } else {
            return error.InvalidCharacter;
        }

        if (result > std.math.maxInt(T) >> 4) {
            return error.Overflow;
        }

        result = (result << 4) | mask;
    }

    return result;
}
