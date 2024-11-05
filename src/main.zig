const std = @import("std");
const xxhash = @import("xxhash.zig");
const fs = std.fs;
const io = std.io;
const mem = std.mem;
const zstd = std.compress.zstd;
const assert = std.debug.assert;
const win = std.os.windows;

extern "kernel32" fn CreateFileMappingA(hFile: win.HANDLE, ?*anyopaque, flProtect: win.DWORD, dwMaximumSizeHigh: win.DWORD, dwMaximumSizeLow: win.DWORD, lpName: ?win.LPCSTR) callconv(win.WINAPI) ?win.HANDLE;

extern "kernel32" fn MapViewOfFile(hFileMappingObject: win.HANDLE, dwDesiredAccess: win.DWORD, dwFileOffsetHigh: win.DWORD, dwFileOffsetLow: win.DWORD, dwNumberOfBytesToMap: win.SIZE_T) callconv(win.WINAPI) ?[*]u8;

extern "kernel32" fn UnmapViewOfFile(lpBaseAddress: win.LPCVOID) callconv(win.WINAPI) win.BOOL;

const c = @cImport({
    @cInclude("zstd.h");
});

const Header = extern struct {
    const Version = extern struct {
        magic: [2]u8,
        major: u8,
        minor: u8,
    };

    version: Version,
    signature: u128 align(1), // idk how to get
    unknown: [240]u8, // idk what should this be
    checksum: u64 align(1), // idk  how to get
    entries_len: u32,
};

const EntryType = enum(u4) {
    raw = 0,
    link,
    gzip,
    zstd,
    zstd_multi,
};

const Entry = packed struct {
    hash: u64,
    offset: u32,
    compressed_len: u32,
    decompressed_len: u32,
    entry_type: EntryType,
    subchunk_len: u4,
    duplicate: u8,
    subchunk: u16,
    checksum: u64,
};

pub fn main() !void { // validating files

    var gpa = std.heap.GeneralPurposeAllocator(.{ .verbose_log = true }){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator(); // todo: use  c_allocator on unsafe release modes

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next().?;

    const src = args.next() orelse return error.ArgumentSrcFileMissing; // now try to extract only a file

    comptime assert(@sizeOf(Header) == 272);
    comptime assert(@sizeOf(Entry) == 32);

    const file = try fs.cwd().openFile(src, .{});
    defer file.close();

    const file_len = try file.getEndPos();
    const maping = CreateFileMappingA(file.handle, null, win.PAGE_READONLY, 0, 0, null).?;
    defer win.CloseHandle(maping);

    const file_buf = MapViewOfFile(maping, 0x4, 0, 0, 0).?;
    defer _ = UnmapViewOfFile(file_buf);

    var file_stream = io.fixedBufferStream(file_buf[0..file_len]);
    const reader = file_stream.reader();

    const header = try reader.readStruct(Header); // idk if league uses a specific endian, my guess is that they do not

    assert(mem.eql(u8, &header.version.magic, "RW"));
    assert(header.version.major == 3);
    assert(header.version.minor == 3);

    var out_list = std.ArrayList(u8).init(allocator);
    defer out_list.deinit();

    var prev_hash: u64 = 0;
    for (header.entries_len) |_| {
        const entry = try reader.readStruct(Entry);
        const gb = 1024 * 1024 * 1024;

        assert(entry.hash >= prev_hash);
        prev_hash = entry.hash;

        assert(4 * gb > entry.compressed_len);
        assert(4 * gb > entry.decompressed_len);
        assert(4 * gb > entry.offset);

        switch (entry.entry_type) {
            .raw => {
                const pos = try file_stream.getPos();
                try file_stream.seekTo(entry.offset);

                assert(entry.compressed_len == entry.decompressed_len);
                assert(file_stream.buffer[file_stream.pos..].len >= entry.compressed_len);

                const in = file_stream.buffer[file_stream.pos .. file_stream.pos + entry.compressed_len];

                const checksum = xxhash.XxHash3(64).hash(in);
                assert(checksum == entry.checksum);

                try file_stream.seekTo(pos);
            },
            .zstd, .gzip, .zstd_multi => {
                const pos = try file_stream.getPos();
                try file_stream.seekTo(entry.offset);

                assert(file_stream.buffer[file_stream.pos..].len >= entry.compressed_len);

                const in = file_stream.buffer[file_stream.pos .. file_stream.pos + entry.compressed_len];

                const magic = [_]u8{ 0x28, 0xB5, 0x2f, 0xfd };
                assert(mem.eql(u8, in[0..4], &magic));

                const checksum = xxhash.XxHash3(64).hash(in);
                assert(checksum == entry.checksum);

                try file_stream.seekTo(pos);
            },
            .link => |t| { // hiping that gzip in zig is now slow.
                std.debug.print("warn: idk how to handle, {s}.\n", .{@tagName(t)});
            },
        }
    }
}

pub fn parsing_main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .verbose_log = true }){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator(); // todo: use  c_allocator on unsafe release modes

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next().?;

    const src = args.next() orelse return error.ArgumentSrcFileMissing; // now try to extract only a file
    const dst = args.next() orelse return error.ArgumentDstDirMissing;

    comptime assert(@sizeOf(Header) == 272);
    comptime assert(@sizeOf(Entry) == 32);

    const file = try fs.cwd().openFile(src, .{});
    defer file.close();

    const file_len = try file.getEndPos();
    const maping = CreateFileMappingA(file.handle, null, win.PAGE_READONLY, 0, 0, null).?;
    defer win.CloseHandle(maping);

    const file_buf = MapViewOfFile(maping, 0x4, 0, 0, 0).?;
    defer _ = UnmapViewOfFile(file_buf);

    var file_stream = io.fixedBufferStream(file_buf[0..file_len]);
    const reader = file_stream.reader();

    var out_dir = try fs.cwd().openDir(dst, .{});
    defer out_dir.close();

    const header = try reader.readStruct(Header); // idk if league uses a specific endian, my guess is that they do not

    assert(mem.eql(u8, &header.magic, "RW"));
    assert(header.version.major == 3);
    assert(header.version.minor == 3);

    var out_list = std.ArrayList(u8).init(allocator);
    defer out_list.deinit();

    var scrape_buf: [256]u8 = undefined;
    for (header.entries_len) |_| {
        const entry = try reader.readStruct(Entry);
        switch (entry.entry_type) {
            .zstd => { // performance not bad, but we probably could multithread (it would be pain to implement)
                const pos = try file_stream.getPos();
                try file_stream.seekTo(entry.offset);

                try out_list.ensureTotalCapacity(entry.decompressed_len);

                assert(out_list.capacity >= entry.decompressed_len);
                assert(file_len - file_stream.pos >= entry.compressed_len);

                const in = file_stream.buffer[file_stream.pos .. file_stream.pos + entry.compressed_len];
                const out = out_list.allocatedSlice()[0..entry.decompressed_len];

                const zstd_len = c.ZSTD_decompress(out.ptr, out.len, in.ptr, in.len); // we could have stack buf and just fill it and write to file, and thus we would not need to alloc mem.
                if (c.ZSTD_isError(zstd_len) == 1) {
                    std.debug.print("err: {s}\n", .{c.ZSTD_getErrorName(zstd_len)});
                }

                try file_stream.seekTo(pos);

                const name = try std.fmt.bufPrint(&scrape_buf, "{x}.dds", .{entry.hash});
                const out_file = try out_dir.createFile(name, .{});
                defer out_file.close();

                try out_file.writeAll(out);
            },
            .raw, .gzip, .link, .zstd_multi => |t| { // hiping that gzip in zig is now slow.
                std.debug.print("warn: idk how to handle, {s}.\n", .{@tagName(t)});
            },
        }
    }
}
