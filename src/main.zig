const Data = @import("data.zig");
const http = @import("httpz");
const routes = @import("routes.zig");
const std = @import("std");
const Parsed = std.json.Parsed;
const Allocator = std.mem.Allocator;

const magic = @cImport(@cInclude("magic.h"));

pub const Config = struct { bindAddress: []const u8, bindPort: u16, dataDir: []const u8 = "data", token: []const u8, domain: []const u8 };

// Must be freed
fn readConfig(alloc: Allocator) !Parsed(Config) {
    const cwd = std.fs.cwd();
    const configFile = try cwd.openFile("config.json", .{});
    const meta = try configFile.metadata();

    const buf = try alloc.alloc(u8, meta.size());
    defer alloc.free(buf);
    _ = try configFile.readAll(buf);

    return std.json.parseFromSlice(Config, alloc, buf, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

// Must be freed
fn initData(alloc: Allocator, config: Config) !Data {
    var dir = try std.fs.cwd().openDir(config.dataDir, .{});
    const file = try dir.createFile("index.json", .{ .read = true, .truncate = false });
    errdefer file.close();

    const meta = try file.metadata();

    var magicHandle = magic.magic_open(magic.MAGIC_EXTENSION);
    errdefer {
        if (magicHandle != null) {
            magic.magic_close(magicHandle);
        }
    }

    if (magicHandle != null and magic.magic_load(magicHandle, null) != 0) {
        const err = magic.magic_error(magicHandle);
        std.debug.print("Loading libmagic failed with: {s}", .{err});
        magic.magic_close(magicHandle);
        magicHandle = null;
    }

    if (meta.size() == 0) {
        const init = Data.Json{ .files = &.{} };
        const writer = file.writer();
        try std.json.stringify(init, .{ .whitespace = .indent_4 }, writer);

        return Data.initConstructed(file, config, magicHandle, alloc, dir);
    }

    const buf = try alloc.alloc(u8, meta.size());
    defer alloc.free(buf);

    _ = try file.readAll(buf);

    const json = try std.json.parseFromSlice(Data.Json, alloc, buf, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    return Data{ .file = file, .json = .{ .parsed = json }, .config = config, .magic = magicHandle, .alloc = alloc, .dir = dir, .rand = Data.initRandom() };
}

pub fn main() !void {
    var alloc = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leak = alloc.deinit();
        if (leak == .leak) {
            std.debug.print("Leak in GPA", .{});
        }
    }

    const parsed = try readConfig(alloc.allocator());
    defer parsed.deinit();

    const config = parsed.value;

    std.fs.cwd().makeDir(config.dataDir) catch |err| {
        if (err != error.PathAlreadyExists) {
            return err;
        }
    };

    var data = try initData(alloc.allocator(), config);
    defer data.deinit();

    var server = try http.ServerCtx(*Data, *Data)
        .init(alloc.allocator(), .{ .address = config.bindAddress, .port = config.bindPort, .request = .{ .max_multiform_count = 1, .max_body_size = 100000000 } }, &data);
    defer server.deinit();

    server.router().post("/stop", routes.stop);
    server.router().post("/upload", routes.upload);
    server.router().get("/:hash", routes.html);
    server.router().get("/:hash/direct", routes.direct);
    server.router().delete("/:hash", routes.delete);

    data.server = &server;
    return server.listen();
}
