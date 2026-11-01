//! Builds a fake index shaped like a real drive, so search can be measured
//! without administrator rights and without waiting on a real MFT scan.
//!
//! The emission order matters as much as the tree does. Reading the MFT hands
//! back records in allocation order, which has nothing to do with directory
//! layout, so `.scattered` is what the real scanner produces and `.tree` is
//! what a depth-first walk would produce.

const std = @import("std");
const idx = @import("index.zig");
const Index = idx.Index;

pub const Order = enum {
    /// Depth first, so a directory is followed by everything under it.
    tree,
    /// Shuffled, the way MFT record numbers relate to directory layout.
    scattered,
};

pub const Options = struct {
    entries: u32 = 3_000_000,
    order: Order = .scattered,
    seed: u64 = 0x5eed,
    /// Roughly how many children a directory holds.
    fanout: u32 = 8,
    max_depth: u32 = 12,
};

const Node = struct {
    parent: u32,
    name_off: u32,
    name_len: u16,
    depth: u16,
    is_dir: bool,
};

const words = [_][]const u8{
    "documents",  "projects", "source",     "build",   "release",  "assets",
    "textures",   "shaders",  "config",     "backup",  "download", "library",
    "modules",    "packages", "vendor",     "runtime", "cache",    "temp",
    "user",       "system",   "windows",    "program", "common",   "shared",
    "engine",     "render",   "audio",      "physics", "network",  "input",
    "editor",     "tools",    "scripts",    "tests",   "samples",  "docs",
    "generated",  "internal", "platform",   "native",  "bindings", "legacy",
};

const extensions = [_][]const u8{
    ".zig", ".c",   ".h",    ".cpp", ".txt", ".md",  ".json", ".xml",
    ".png", ".jpg", ".wav",  ".dll", ".exe", ".lib", ".obj",  ".log",
};

fn writeName(buf: []u8, rand: std.Random, is_dir: bool) usize {
    var len: usize = 0;
    const parts = 1 + rand.uintLessThan(usize, 2);
    for (0..parts) |k| {
        if (k > 0 and len < buf.len) {
            buf[len] = '_';
            len += 1;
        }
        const word = words[rand.uintLessThan(usize, words.len)];
        const n = @min(word.len, buf.len - len);
        @memcpy(buf[len..][0..n], word[0..n]);
        len += n;
    }
    // A number on some of them, the way real trees carry versions and indices.
    if (rand.uintLessThan(u32, 100) < 35 and len + 4 < buf.len) {
        const digits = std.fmt.bufPrint(buf[len..], "{d}", .{rand.uintLessThan(u32, 5000)}) catch buf[len..len];
        len += digits.len;
    }
    if (!is_dir) {
        const ext = extensions[rand.uintLessThan(usize, extensions.len)];
        const n = @min(ext.len, buf.len - len);
        @memcpy(buf[len..][0..n], ext[0..n]);
        len += n;
    }
    return len;
}

/// Sizes on a real drive span ten orders of magnitude and cluster at the small
/// end, so this draws the exponent rather than the number. Drawn flat instead,
/// every file would come out around two gigabytes and the column would be a
/// wall of the same figure.
fn fakeSize(rand: std.Random) u64 {
    const magnitude = rand.uintLessThan(u6, 33);
    const floor = @as(u64, 1) << magnitude;
    return floor + rand.uintLessThan(u64, floor);
}

/// A Windows file time in the five years from 2020, in 100 ns ticks from 1601.
fn fakeTime(rand: std.Random) i64 {
    const start: i64 = 132_223_104_000_000_000;
    const span: i64 = 5 * 365 * 24 * 60 * 60 * 10_000_000;
    return start + rand.intRangeLessThan(i64, 0, span);
}

pub fn build(index: *Index, opts: Options) !void {
    const gpa = index.gpa;
    var prng = std.Random.DefaultPrng.init(opts.seed);
    const rand = prng.random();

    var nodes: std.ArrayList(Node) = .empty;
    defer nodes.deinit(gpa);
    var blob: std.ArrayList(u8) = .empty;
    defer blob.deinit(gpa);

    // Root, named the way a volume root is.
    try blob.appendSlice(gpa, "C:");
    try nodes.append(gpa, .{ .parent = 0, .name_off = 0, .name_len = 2, .depth = 0, .is_dir = true });

    var queue: std.ArrayList(u32) = .empty;
    defer queue.deinit(gpa);
    try queue.append(gpa, 0);

    var name_buf: [64]u8 = undefined;
    var head: usize = 0;
    while (nodes.items.len < opts.entries) {
        if (head == queue.items.len) break;
        const parent = queue.items[head];
        head += 1;
        const depth = nodes.items[parent].depth;

        // Subdirectories are handed out explicitly rather than rolled per
        // child, so the tree always keeps growing until the count is reached.
        const files = opts.fanout / 2 + rand.uintLessThan(u32, opts.fanout);
        const subdirs: u32 = if (depth + 1 < opts.max_depth)
            2 + rand.uintLessThan(u32, 4)
        else
            0;

        for (0..files + subdirs) |k| {
            if (nodes.items.len >= opts.entries) break;
            const is_dir = k >= files;

            const n = writeName(&name_buf, rand, is_dir);
            const off: u32 = @intCast(blob.items.len);
            try blob.appendSlice(gpa, name_buf[0..n]);

            const id: u32 = @intCast(nodes.items.len);
            try nodes.append(gpa, .{
                .parent = parent,
                .name_off = off,
                .name_len = @intCast(n),
                .depth = depth + 1,
                .is_dir = is_dir,
            });
            if (is_dir) try queue.append(gpa, id);
        }
    }

    // Emission order. The root has to land first so it can point at itself.
    const order = try gpa.alloc(u32, nodes.items.len);
    defer gpa.free(order);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    if (opts.order == .scattered) rand.shuffle(u32, order[1..]);

    const slot = try gpa.alloc(u32, nodes.items.len);
    defer gpa.free(slot);
    for (order, 0..) |node_id, i| slot[node_id] = @intCast(i);

    try index.entries.ensureTotalCapacity(gpa, nodes.items.len);
    try index.names.ensureTotalCapacity(gpa, blob.items.len);
    for (order) |node_id| {
        const node = nodes.items[node_id];
        const name = blob.items[node.name_off..][0..node.name_len];
        const off = try index.addName(name);
        _ = try index.addEntry(.{
            .name_off = off,
            .parent = slot[node.parent],
            .name_len = node.name_len,
            .bloom = idx.bloomOf(name),
            .path_bloom = 0,
            .is_dir = node.is_dir,
            // Zero on a directory is what the master file table pass leaves,
            // and what the Size column reads as nothing to show.
            .size = if (node.is_dir) 0 else fakeSize(rand),
            .modified = fakeTime(rand),
        });
    }

    try index.computePathBlooms(0);
    try index.volumes.append(gpa, .{ .letter = 'C', .root = 0 });
}

test "the tree is well formed in either order" {
    const gpa = std.testing.allocator;
    for ([_]Order{ .tree, .scattered }) |order| {
        var index = Index.init(gpa);
        defer index.deinit();
        try build(&index, .{ .entries = 5000, .order = order });

        try std.testing.expectEqual(@as(u32, 5000), index.count());

        // Every path has to reach the root, and only the root is its own parent.
        const parents = index.entries.slice().items(.parent);
        var roots: usize = 0;
        for (parents, 0..) |p, i| {
            if (p == i) roots += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), roots);

        var buf: [1024]u8 = undefined;
        for (0..index.count()) |i| {
            const full = index.path(@intCast(i), &buf);
            try std.testing.expect(std.mem.startsWith(u8, full, "C:"));
        }
    }
}

test "the depth first reorder keeps every path and puts parents first" {
    const gpa = std.testing.allocator;
    var index = Index.init(gpa);
    defer index.deinit();
    try build(&index, .{ .entries = 20_000, .order = .scattered });

    var before = try collectPaths(gpa, &index);
    defer freePaths(gpa, &before);

    try index.orderDepthFirst();

    var after = try collectPaths(gpa, &index);
    defer freePaths(gpa, &after);

    try std.testing.expectEqual(before.items.len, after.items.len);
    for (before.items, after.items) |x, y| try std.testing.expectEqualStrings(x, y);

    // A scan that carries a stack of ancestors needs every parent to have
    // been seen before any of its children.
    const parents = index.entries.slice().items(.parent);
    for (parents, 0..) |p, i| {
        if (p == i) continue;
        try std.testing.expect(p < i);
    }
}

fn collectPaths(gpa: std.mem.Allocator, index: *Index) !std.ArrayList([]u8) {
    var list: std.ArrayList([]u8) = .empty;
    var buf: [1024]u8 = undefined;
    for (0..index.count()) |i| {
        try list.append(gpa, try gpa.dupe(u8, index.path(@intCast(i), &buf)));
    }
    std.mem.sort([]u8, list.items, {}, lessThanSlice);
    return list;
}

fn lessThanSlice(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn freePaths(gpa: std.mem.Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |x| gpa.free(x);
    list.deinit(gpa);
}
