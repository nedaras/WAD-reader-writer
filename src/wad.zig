const std = @import("std");

const fs = std.fs;
const io = std.io;
const mem = std.mem;
const print = std.debug.print;
const Allocator = mem.Allocator;
const File = fs.File;

const Version = extern struct {
    magic: [2]u8,
    major: u8,
    minor: u8,

    fn latest() Version {
        return .{ .magic = [_]u8{ 'R', 'W' }, .major = 3, .minor = 3 };
    }
};

const HeaderV3 = extern struct {
    signature: [16]u8,
    signature_unused: [240]u8,
    checksum: [8]u8,
    entries_count: u32,
};

const EntryV3 = packed struct {
    hash: u64,
    offset: u32,
    size_compressed: u32,
    size_decompressed: u32,
    type: u4,
    subchunk_count: u4,
    is_duplicate: u8,
    subchunk_index: u16,
    checksum_old: u64,
};

pub const WADFile = struct {
    file: File,
    entries_count: u32,

    entry_index: u32 = 0,
    hash_maps: std.AutoHashMapUnmanaged(u8, []u8) = .{},

    pub const OpenError = error{
        InvalidVersion,
    };

    pub fn next(self: *WADFile) !?EntryV3 {
        if (self.entry_index >= self.entries_count) return null;

        self.entry_index += 1;

        // is reader like a ptr or struct?
        // it is soo i guess it better to have reader class
        const reader = self.file.reader();
        return try reader.readStruct(EntryV3);
    }

    // aaa it has to be comptime, bad idea we have here
    pub fn getBuffer(self: *WADFile, entry: EntryV3) type {
        _ = self;
        return struct {
            const Self = @This();

            allocator: Allocator,
            buffer: []u8,

            pub fn init(allocator: Allocator) !Self {
                var buffer = try allocator.alloc(u8, entry.size_compressed);
                return .{ .allocator = allocator, .buffer = buffer };
            }

            pub fn deinit(selff: Self) void {
                selff.allocator.free(selff.buffer);
            }
        };
    }

    pub fn close(self: WADFile) void {
        self.file.close();
    }
};

pub fn openFile(path: []const u8) !WADFile {
    const file = try fs.cwd().openFile(path, .{ .mode = .read_write });
    errdefer file.close();

    const reader = file.reader(); // we can read ver and head with one sys call

    const version = try reader.readStruct(Version);

    if (!std.meta.eql(version, Version.latest())) return WADFile.OpenError.InvalidVersion;

    const header = try reader.readStruct(HeaderV3);

    return .{
        .file = file,
        .entries_count = header.entries_count,
    };
}
