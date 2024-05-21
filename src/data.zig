const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const http = @import("httpz");
const Config = @import("main.zig").Config;
const Parsed = std.json.Parsed;
const Mutex = std.Thread.Mutex;

const libmagic = @cImport(@cInclude("magic.h"));
const magic_t = libmagic.magic_t;
const magic_close = libmagic.magic_close;

pub const File = struct { name: []const u8, hash: []const u8 };

pub const Json = struct { files: []File };
pub const ConstructedJson = struct { files: ArrayList(File) };

const UnionType = enum { parsed, constructed };

pub const Inner = union(UnionType) { parsed: Parsed(Json), constructed: ConstructedJson };

pub fn initRandom() std.rand.Xoshiro256 {
    const iSeed = std.time.milliTimestamp();
    const seed: u64 = @intCast(@abs(iSeed));

    return std.rand.DefaultPrng.init(seed);
}

file: std.fs.File,
json: Inner,
server: ?*http.ServerCtx(*@This(), *@This()) = null,
config: Config,
magic: magic_t,
mutex: Mutex = Mutex{},
alloc: Allocator,
dir: std.fs.Dir,
rand: std.rand.Xoshiro256,

pub fn initConstructed(file: std.fs.File, config: Config, magic: magic_t, alloc: Allocator, dir: std.fs.Dir) @This() {
    const list = ArrayList(File).init(alloc);
    return @This(){ .file = file, .config = config, .magic = magic, .json = .{ .constructed = ConstructedJson{ .files = list } }, .alloc = alloc, .dir = dir, .rand = initRandom() };
}

fn freeFiles(alloc: Allocator, files: ArrayList(File)) void {
    for (files.items) |file| {
        alloc.free(file.name);
        alloc.free(file.hash);
    }
}

pub fn deinit(self: *@This()) void {
    self.file.close();
    self.dir.close();
    switch (self.json) {
        .parsed => |parsed| {
            parsed.deinit();
        },
        .constructed => |it| {
            freeFiles(self.alloc, it.files);
            it.files.deinit();
        },
    }

    if (self.magic != null) {
        magic_close(self.magic);
    }
}

// Deinits self.json if it is .parsed
fn toConstructed(self: *@This()) !ConstructedJson {
    return switch (self.json) {
        .parsed => |parsed| blk: {
            var list = ArrayList(File).init(self.alloc);
            errdefer list.deinit();

            for (parsed.value.files) |file| {
                const nameHeap = try self.alloc.alloc(u8, file.name.len);
                @memcpy(nameHeap, file.name);
                const hashHeap = try self.alloc.alloc(u8, file.hash.len);
                @memcpy(hashHeap, file.hash);

                try list.append(File{ .name = nameHeap, .hash = hashHeap });
            }

            parsed.deinit();
            break :blk ConstructedJson{ .files = list };
        },
        .constructed => |constructed| constructed,
    };
}

fn writeJson(self: @This()) !void {
    // Overwrite
    try self.file.seekTo(0);
    try self.file.setEndPos(0);

    try std.json.stringify(Json{ .files = self.json.constructed.files.items }, .{ .whitespace = .indent_4 }, self.file.writer());
}

pub fn addFile(self: *@This(), name: []const u8, hash: []const u8, data: []const u8) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    var existing = try self.toConstructed();
    existing.files.append(File{ .name = name, .hash = hash }) catch |err| {
        freeFiles(self.alloc, existing.files);
        existing.files.deinit();
        return err;
    };

    self.json = .{ .constructed = existing };

    try self.writeJson();

    self.dir.makeDir("media") catch |err| {
        if (err != error.PathAlreadyExists) {
            return err;
        }
    };

    var media = try self.dir.openDir("media", .{});
    defer media.close();

    const mediaFile = try media.createFile(hash, .{ .truncate = false, .exclusive = true });
    defer mediaFile.close();

    try mediaFile.writeAll(data);
}

pub fn getFiles(self: @This()) []File {
    switch (self.json) {
        .constructed => |it| {
            return it.files.items;
        },
        .parsed => |it| {
            return it.value.files;
        },
    }
}

// Returns whether the file existed
pub fn deleteFile(self: *@This(), hash: []const u8) !bool {
    self.mutex.lock();
    defer self.mutex.unlock();

    var existing = try self.toConstructed();

    var index: ?usize = null;
    for (0..existing.files.items.len) |i| {
        if (std.mem.eql(u8, existing.files.items[i].hash, hash)) {
            index = i;
            break;
        }
    }

    if (index) |idx| {
        self.alloc.free(existing.files.items[idx].name);
        self.alloc.free(existing.files.items[idx].hash);
        _ = existing.files.swapRemove(idx);
    }

    self.json = .{ .constructed = existing };

    try self.writeJson();

    const subPath = try std.fmt.allocPrint(self.alloc, "media/{s}", .{hash});
    defer self.alloc.free(subPath);

    try self.dir.deleteFile(subPath);

    return index != null;
}
