const std = @import("std");
const builtin = @import("builtin");
const errors = @import("../errors.zig");
const mapping = @import("../mapping.zig");
const wad = @import("../wad.zig");
const hashes = @import("../hashes.zig");
const handled = @import("../handled.zig");
const Options = @import("../cli.zig").Options;
const logger = @import("../logger.zig");
const fs = std.fs;
const io = std.io;
const HandleError = handled.HandleError;
const Allocator = std.mem.Allocator;

pub fn extract(allocator: Allocator, options: Options) !void {
    const hashes_map = if (options.hashes) |h| try handled.map(fs.cwd(), h, .{}) else null;
    defer if (hashes_map) |h| h.deinit();

    //const game_hashes = if (hashes_map) |h| hashes.decompressor(h.view) else null;

    const stdout = std.io.getStdOut();
    var bw = io.bufferedWriter(stdout.writer());

    const writer = bw.writer();

    var window_buf: [1 << 17]u8 = undefined;
    if (options.file == null) {
        const stdin = io.getStdIn();
        if (std.posix.isatty(stdin.handle)) {
            logger.println("Refusing to read archive contents from terminal (missing -f option?)", .{});
            return error.Fatal;
        }

        var br = io.bufferedReader(stdin.reader());
        var iter = try wad.streamIterator(allocator, br.reader(), .{
            .handle_duplicates = false,
            .window_buffer = &window_buf,
        });
        defer iter.deinit();

        while (try iter.next()) |entry| {
            if (entry.duplicate()) {
                continue;
            }
            _ = writer;

            var amt: usize = 0;
            while (entry.decompressed_len > amt) { // fix this stuff
                var buf: [4096]u8 = undefined;
                const len = try entry.read(&buf);
                amt += len;
            }
            if (entry.decompressed_len != amt) {
                std.debug.print("len: {d} ", .{amt});
                @panic("not same lens");
            }
        }

        bw.flush() catch return;

        return;
    }
    @panic("not implemented");
    // when reading for mmap file, we should read it from steam iter, unless if multithreading is used
    // mb would be nice to, like err if reading stdin after extraction is not empty
}
