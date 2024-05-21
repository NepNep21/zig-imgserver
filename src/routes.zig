const Data = @import("data.zig");
const http = @import("httpz");
const Request = http.Request;
const Response = http.Response;
const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

const magic_buffer = @cImport(@cInclude("magic.h")).magic_buffer;

const EXT_MAX = 10;

fn isAuthorized(ctx: *Data, req: *Request) bool {
    return std.mem.eql(u8, req.header("authorization") orelse &.{}, ctx.config.token);
}

pub fn stop(ctx: *Data, req: *Request, resp: *Response) !void {
    if (!isAuthorized(ctx, req)) {
        resp.status = 401;
        resp.body = "Unauthorized";
        return;
    }

    resp.status = 200;
    resp.body = "OK";
    ctx.server.?.stop();
}

fn getExtension(ctx: *Data, data: []const u8, arena: std.mem.Allocator) ![]u8 {
    const extensions = magic_buffer(ctx.magic, data.ptr, data.len);

    const first = try arena.alloc(u8, EXT_MAX);

    var i: u4 = 0;
    while (i < EXT_MAX and extensions[i] != '/') : (i += 1) { // First extension
        first[i] = extensions[i];

        // Null terminator
        if (first[i] == 0) {
            break;
        }
    }

    const ret: []u8 = try arena.realloc(first, i);
    return ret;
}

pub fn upload(ctx: *Data, req: *Request, resp: *Response) !void {
    if (!isAuthorized(ctx, req)) {
        resp.status = 401;
        resp.body = "Unauthorized";
        return;
    }

    // startsWith due to boundary
    if (!std.mem.startsWith(u8, req.header("content-type") orelse &.{}, "multipart/form-data")) {
        resp.status = 400;
        resp.body = "Bad Request";
        return;
    }

    const body = try req.multiFormData();
    const value = body.get("file") orelse {
        resp.status = 400;
        resp.body = "Bad Request";
        return;
    };

    const data = value.value;

    var hash = Sha256.init(.{});
    hash.update(data);
    const digestBytes = hash.finalResult();
    const digestStack = std.fmt.bytesToHex(digestBytes, .lower);

    // Free in Data
    const digest = try ctx.alloc.alloc(u8, digestStack.len);
    @memcpy(digest, digestStack[0..]);

    ctx.mutex.lock();
    for (ctx.getFiles()) |file| {
        if (std.mem.eql(u8, file.hash, digest)) {
            ctx.alloc.free(digest);

            resp.status = 409;
            resp.body = "Already Exists";
            return;
        }
    }
    ctx.mutex.unlock();

    // Free in Data
    var name: []u8 = undefined;
    if (value.filename) |filename| {
        name = try ctx.alloc.alloc(u8, filename.len);
        @memcpy(name, filename);
    } else {
        const base = "image";
        name = try ctx.alloc.alloc(u8, base.len + EXT_MAX);
        _ = try std.fmt.bufPrint(name, "{s}.{s}", .{ base, try getExtension(ctx, data, resp.arena) });
        const len = (std.mem.indexOf(u8, name, &.{0}) orelse name.len - 1) + 1;
        name = try ctx.alloc.realloc(name, len);
    }

    try ctx.addFile(name, digest, data);

    resp.status = 200;
    resp.body = try std.fmt.allocPrint(resp.arena, "https://{s}/{s}", .{ ctx.config.domain, digest });
}

pub fn direct(ctx: *Data, req: *Request, res: *Response) !void {
    const param = req.param("hash") orelse {
        res.status = 400;
        res.body = "Bad Request";
        return;
    };

    var name: ?[]const u8 = null;
    ctx.mutex.lock();
    for (ctx.getFiles()) |file| {
        if (std.mem.eql(u8, file.hash, param)) {
            name = file.name;
        }
    }
    ctx.mutex.unlock();

    if (name == null) {
        res.status = 404;
        res.body = "Not Found";
        return;
    }

    var dir = ctx.dir.openDir("media", .{}) catch |err| {
        if (err == error.FileNotFound) {
            res.status = 404;
            res.body = "Not Found";
            return;
        }
        return err;
    };
    defer dir.close();

    const file = dir.openFile(param, .{}) catch |err| {
        if (err == error.FileNotFound) {
            res.status = 404;
            res.body = "Not Found";
            return;
        }
        return err;
    };
    defer file.close();

    const meta = try file.metadata();

    const data = try res.arena.alloc(u8, meta.size());
    _ = try file.readAll(data);

    var extIter = std.mem.splitBackwards(u8, name.?, ".");
    const ext = extIter.first();

    res.status = 200;
    res.body = data;
    res.content_type = http.ContentType.forExtension(ext);
    res.header("Content-Disposition", try std.fmt.allocPrint(res.arena, "attachment; filename={s}", .{name.?}));
}

pub fn html(ctx: *Data, req: *Request, res: *Response) !void {
    const param = req.param("hash") orelse {
        res.status = 400;
        res.body = "Bad Request";
        return;
    };

    var exists = false;
    var name: ?[]const u8 = null;

    ctx.mutex.lock();
    for (ctx.getFiles()) |file| {
        exists = std.mem.eql(u8, file.hash, param);
        if (exists) {
            name = file.name;
            break;
        }
    }
    ctx.mutex.unlock();

    if (!exists) {
        res.status = 404;
        res.body = "Not Found";
        return;
    }

    const directUrl = try std.fmt.allocPrint(res.arena, "https://{s}{s}/direct", .{ ctx.config.domain, req.url.raw });

    const descriptions: [2][]const u8 = .{ "&quot;ppl boycott rooms bc of them lol&quot;", "achieved niche-internet-micro-infamy" };
    const description = descriptions[ctx.rand.random().intRangeAtMost(usize, 0, descriptions.len - 1)];

    const raw = @embedFile("index.html");

    const withName = try std.mem.replaceOwned(u8, res.arena, raw, "zig_img-name", name.?);

    const withUrl = try std.mem.replaceOwned(u8, res.arena, withName, "zig_img-url", directUrl);
    res.arena.free(withName);

    const withDescription = try std.mem.replaceOwned(u8, res.arena, withUrl, "zig_description", description);
    res.arena.free(withUrl);

    res.status = 200;
    res.body = withDescription;
}

pub fn delete(ctx: *Data, req: *Request, res: *Response) !void {
    if (!isAuthorized(ctx, req)) {
        res.status = 401;
        res.body = "Unauthorized";
        return;
    }

    const param = req.param("hash") orelse {
        res.status = 400;
        res.body = "Bad Request";
        return;
    };

    if (try ctx.deleteFile(param)) {
        res.status = 200;
    } else {
        res.status = 404;
        res.body = "Not Found";
    }
}
