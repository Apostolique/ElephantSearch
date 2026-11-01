//! In-memory file index. Names live in one flat blob, entries point into it,
//! and full paths get rebuilt on demand by walking the parent chain. Only the
//! rows a query actually reaches ever pay for path construction.

const std = @import("std");
const w = @import("win32.zig");
const Allocator = std.mem.Allocator;

/// Deepest parent chain a path is allowed to have. NTFS tops out well below
/// this, so hitting it means the chain is corrupt or looped.
pub const max_depth = 512;

pub const Entry = struct {
    name_off: u32,
    /// Index of the containing directory. A volume root points at itself.
    parent: u32,
    name_len: u16,
    /// Set of characters present in the name, folded to lowercase. A query
    /// whose own set is not a subset can be rejected without touching the name.
    bloom: u32,
    /// Same, unioned over every ancestor, so a path search can reject an entry
    /// without rebuilding its path.
    path_bloom: u32,
    /// Bytes in the file. Zero for a directory, and for anything the master
    /// file table pass could not or did not read.
    size: u64 = 0,
    /// Windows file time, 100 ns ticks from 1601. Zero when unknown.
    modified: i64 = 0,
    is_dir: bool,
};

/// A half-open run of entry indices.
pub const Range = struct { from: u32, to: u32 };

pub const Volume = struct {
    letter: u8,
    root: u32,
    frn_map: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    journal_id: u64 = 0,
    next_usn: i64 = 0,
};

pub const Index = struct {
    gpa: Allocator,
    entries: std.MultiArrayList(Entry) = .empty,
    names: std.ArrayList(u8) = .empty,
    volumes: std.ArrayList(Volume) = .empty,
    /// Set when a directory is renamed, which leaves every path bloom under it
    /// missing the new name's characters. Only a rebuild fixes that.
    layout_stale: bool = false,
    /// How many entries `orderDepthFirst` laid out. Anything the change journal
    /// added since is appended past this and belongs to no subtree run.
    ordered: u32 = 0,
    /// Held while entries are added, and by any background pass writing into
    /// them, because appending can move every array out from under it. Searches
    /// do not take it: they run on the thread that does the adding.
    growing: w.Lock = .{},

    pub fn init(gpa: Allocator) Index {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Index) void {
        for (self.volumes.items) |*v| v.frn_map.deinit(self.gpa);
        self.volumes.deinit(self.gpa);
        self.entries.deinit(self.gpa);
        self.names.deinit(self.gpa);
    }

    pub fn count(self: *const Index) u32 {
        return @intCast(self.entries.len);
    }

    pub fn nameOf(self: *const Index, i: u32) []const u8 {
        const s = self.entries.slice();
        return self.names.items[s.items(.name_off)[i]..][0..s.items(.name_len)[i]];
    }

    /// Appends a name to the blob and returns its offset. Names are never
    /// removed, so a rename-heavy session grows the blob slowly.
    pub fn addName(self: *Index, name: []const u8) !u32 {
        const off: u32 = @intCast(self.names.items.len);
        try self.names.appendSlice(self.gpa, name);
        return off;
    }

    pub fn addEntry(self: *Index, e: Entry) !u32 {
        const i: u32 = @intCast(self.entries.len);
        try self.entries.append(self.gpa, e);
        return i;
    }

    /// Writes the full path of `i` at the front of `buf` and returns its
    /// length. `stack` holds the ancestor chain and is scratch space.
    pub fn pathInto(self: *const Index, i: u32, buf: []u8, stack: *[max_depth]u32) usize {
        const s = self.entries.slice();
        const parents = s.items(.parent);
        const offs = s.items(.name_off);
        const lens = s.items(.name_len);

        var depth: usize = 0;
        var cur = i;
        while (depth < max_depth) {
            stack[depth] = cur;
            depth += 1;
            const p = parents[cur];
            if (p == cur) break;
            cur = p;
        }

        var len: usize = 0;
        while (depth > 0) {
            depth -= 1;
            const e = stack[depth];
            if (len > 0) {
                if (len == buf.len) break;
                buf[len] = '\\';
                len += 1;
            }
            const n = @min(lens[e], buf.len - len);
            @memcpy(buf[len..][0..n], self.names.items[offs[e]..][0..n]);
            len += n;
            if (len == buf.len) break;
        }
        return len;
    }

    pub fn path(self: *const Index, i: u32, buf: []u8) []const u8 {
        var stack: [max_depth]u32 = undefined;
        return buf[0..self.pathInto(i, buf, &stack)];
    }

    /// Retires an entry without moving anything, so every other index stays
    /// valid. An empty name and an empty bloom make every query skip it.
    pub fn kill(self: *Index, i: u32) void {
        const s = self.entries.slice();
        s.items(.name_len)[i] = 0;
        s.items(.bloom)[i] = 0;
        s.items(.path_bloom)[i] = 0;
    }

    /// Points an entry at a new name and parent. The old name stays in the
    /// blob, so a rename-heavy session grows it slowly.
    pub fn rename(self: *Index, i: u32, name: []const u8, parent: u32) !void {
        const off = try self.addName(name);
        const s = self.entries.slice();
        s.items(.name_off)[i] = off;
        s.items(.name_len)[i] = @intCast(name.len);
        s.items(.bloom)[i] = bloomOf(name);
        s.items(.parent)[i] = parent;
        s.items(.path_bloom)[i] = bloomOf(name) | s.items(.path_bloom)[parent];
        // Everything under a renamed directory now has the wrong path bloom and
        // the wrong stored path, which would hide those files from a search.
        if (s.items(.is_dir)[i]) self.layout_stale = true;
    }

    pub fn isDir(self: *const Index, i: u32) bool {
        return self.entries.slice().items(.is_dir)[i];
    }

    /// The contiguous run of entries a directory owns. Depth-first order puts a
    /// directory immediately before its whole subtree, so the run ends at the
    /// first entry whose parent sits outside what has been covered so far.
    pub fn subtree(self: *const Index, dir: u32) Range {
        const parents = self.entries.slice().items(.parent);
        var end = dir + 1;
        while (end < self.ordered and parents[end] >= dir and parents[end] < end) : (end += 1) {}
        return .{ .from = dir, .to = end };
    }

    /// Resolves `C:\Program Files` to its entry, ignoring case and taking either
    /// separator. Returns null when no such directory is indexed.
    pub fn findPath(self: *const Index, text: []const u8) ?u32 {
        var parts = std.mem.tokenizeAny(u8, text, "\\/");
        const drive = parts.next() orelse return null;

        var cur: u32 = for (self.volumes.items) |vol| {
            if (std.ascii.eqlIgnoreCase(self.nameOf(vol.root), drive)) break vol.root;
        } else return null;

        while (parts.next()) |part| cur = self.childNamed(cur, part) orelse return null;
        return cur;
    }

    /// Whether `entry` sits anywhere under `root`. Needed for the entries the
    /// change journal appends, which land past every subtree run and so cannot
    /// be recognised by their index alone.
    pub fn descendsFrom(self: *const Index, entry: u32, root: u32) bool {
        const parents = self.entries.slice().items(.parent);
        var cur = entry;
        var steps: usize = 0;
        while (steps < max_depth) : (steps += 1) {
            if (cur == root) return true;
            const p = parents[cur];
            if (p == cur) return false;
            cur = p;
        }
        return false;
    }

    fn childNamed(self: *const Index, dir: u32, name: []const u8) ?u32 {
        const parents = self.entries.slice().items(.parent);
        const run = self.subtree(dir);
        var i = run.from + 1;
        while (i < run.to) : (i += 1) {
            if (parents[i] == dir and std.ascii.eqlIgnoreCase(self.nameOf(i), name)) return i;
        }
        return null;
    }

    pub fn isDead(self: *const Index, i: u32) bool {
        return self.entries.slice().items(.name_len)[i] == 0;
    }

    /// Fills in `path_bloom` for every entry from `from` on. Parents can sit
    /// anywhere in the array, so each chain is walked once and memoised.
    pub fn computePathBlooms(self: *Index, from: u32) !void {
        const s = self.entries.slice();
        const blooms = s.items(.bloom);
        const path_blooms = s.items(.path_bloom);
        const parents = s.items(.parent);

        var stack: std.ArrayList(u32) = .empty;
        defer stack.deinit(self.gpa);

        var i = from;
        while (i < self.entries.len) : (i += 1) {
            if (path_blooms[i] != 0) continue;
            stack.clearRetainingCapacity();

            // Climb to the nearest ancestor that already has one.
            var cur = i;
            while (path_blooms[cur] == 0) {
                try stack.append(self.gpa, cur);
                const p = parents[cur];
                if (p == cur or stack.items.len >= max_depth) {
                    path_blooms[cur] = blooms[cur];
                    _ = stack.pop();
                    break;
                }
                cur = p;
            }

            var acc = path_blooms[cur];
            while (stack.pop()) |e| {
                acc |= blooms[e];
                path_blooms[e] = acc;
            }
        }
    }

    /// Reorders entries into a depth first walk of the tree.
    ///
    /// Reading the MFT hands back records in allocation order, which has
    /// nothing to do with directory layout. Laid out this way instead, every
    /// entry sits right after its parent, so a scan can keep a stack of the
    /// directories it is currently inside and each entry only costs its own
    /// name rather than a fresh walk up a chain of ancestors.
    pub fn orderDepthFirst(self: *Index) !void {
        const n = self.entries.len;
        if (n == 0) return;
        const gpa = self.gpa;
        var slice = self.entries.slice();
        const parents = slice.items(.parent);

        // Children of each entry, bucketed by parent.
        const offsets = try gpa.alloc(u32, n + 1);
        defer gpa.free(offsets);
        @memset(offsets, 0);
        for (parents, 0..) |p, i| {
            if (p != i) offsets[p + 1] += 1;
        }
        for (1..n + 1) |k| offsets[k] += offsets[k - 1];

        const children = try gpa.alloc(u32, n);
        defer gpa.free(children);
        {
            const cursor = try gpa.alloc(u32, n);
            defer gpa.free(cursor);
            @memcpy(cursor, offsets[0..n]);
            for (parents, 0..) |p, i| {
                if (p == i) continue;
                children[cursor[p]] = @intCast(i);
                cursor[p] += 1;
            }
        }

        // Siblings by name, which costs one sort of each directory's children
        // and makes the finished array read in path order. Sorting results by
        // path is then a comparison of two entry numbers rather than a walk up
        // two parent chains, which on three million rows is the difference
        // between a frame and a second and a half.
        {
            const by: SiblingOrder = .{
                .names = self.names.items,
                .offs = slice.items(.name_off),
                .lens = slice.items(.name_len),
            };
            for (0..n) |p| {
                const brood = children[offsets[p]..offsets[p + 1]];
                if (brood.len > 1) std.sort.pdq(u32, brood, by, SiblingOrder.lessThan);
            }
        }

        // Depth first, so a directory is immediately followed by its whole
        // subtree. Walking the array then walks the tree, and a search can
        // carry a stack of ancestors instead of rediscovering them per entry.
        const order = try gpa.alloc(u32, n);
        defer gpa.free(order);
        var out: usize = 0;

        var frames: [max_depth]struct { node: u32, next: u32 } = undefined;
        for (self.volumes.items) |vol| {
            order[out] = vol.root;
            out += 1;
            var depth: usize = 1;
            frames[0] = .{ .node = vol.root, .next = offsets[vol.root] };
            while (depth > 0) {
                const f = &frames[depth - 1];
                if (f.next == offsets[f.node + 1]) {
                    depth -= 1;
                    continue;
                }
                const child = children[f.next];
                f.next += 1;
                order[out] = child;
                out += 1;
                if (depth < max_depth) {
                    frames[depth] = .{ .node = child, .next = offsets[child] };
                    depth += 1;
                }
            }
        }

        const old_to_new = try gpa.alloc(u32, n);
        defer gpa.free(old_to_new);
        @memset(std.mem.sliceAsBytes(old_to_new), 0xFF);
        for (order[0..out], 0..) |old, new| old_to_new[old] = @intCast(new);

        // Anything no parent chain reached keeps a place at the end.
        for (0..n) |i| {
            if (old_to_new[i] != std.math.maxInt(u32)) continue;
            old_to_new[i] = @intCast(out);
            order[out] = @intCast(i);
            out += 1;
        }
        std.debug.assert(out == n);

        // Every field, or the ones left behind stay attached to whatever entry
        // lands on their old index. A restored index is laid out again once
        // enough files have been added under it, and it arrives from the cache
        // with every size and date already filled in.
        try permute(u32, gpa, slice.items(.name_off), order);
        try permute(u32, gpa, slice.items(.parent), order);
        try permute(u16, gpa, slice.items(.name_len), order);
        try permute(u32, gpa, slice.items(.bloom), order);
        try permute(u32, gpa, slice.items(.path_bloom), order);
        try permute(u64, gpa, slice.items(.size), order);
        try permute(i64, gpa, slice.items(.modified), order);
        try permute(bool, gpa, slice.items(.is_dir), order);

        for (slice.items(.parent)) |*p| p.* = old_to_new[p.*];
        for (self.volumes.items) |*vol| {
            vol.root = old_to_new[vol.root];
            var it = vol.frn_map.valueIterator();
            while (it.next()) |v| v.* = old_to_new[v.*];
        }

        // The names follow, otherwise walking entries in the new order jumps
        // around the blob and gives back what the reorder just won. Retired
        // entries have no name left to copy, so this compacts them out too.
        var fresh: std.ArrayList(u8) = .empty;
        errdefer fresh.deinit(gpa);
        try fresh.ensureTotalCapacity(gpa, self.names.items.len);
        for (slice.items(.name_off), slice.items(.name_len)) |*off, len| {
            const was = off.*;
            off.* = @intCast(fresh.items.len);
            fresh.appendSliceAssumeCapacity(self.names.items[was..][0..len]);
        }
        self.names.deinit(gpa);
        self.names = fresh;
        self.ordered = @intCast(n);
    }

    /// Rebuilds every path bloom. Only needed after a directory rename moves a
    /// whole subtree.
    pub fn refreshLayout(self: *Index) !void {
        @memset(self.entries.slice().items(.path_bloom), 0);
        try self.computePathBlooms(0);
        self.layout_stale = false;
    }
};

/// Rewrites `items` so that slot `k` holds what slot `order[k]` used to.
fn permute(comptime T: type, gpa: Allocator, items: []T, order: []const u32) !void {
    const scratch = try gpa.alloc(T, items.len);
    defer gpa.free(scratch);
    for (order, 0..) |old, new| scratch[new] = items[old];
    @memcpy(items, scratch);
}

/// Bit per character class, matching `Entry.bloom`.
pub fn bloomOf(name: []const u8) u32 {
    var mask: u32 = 0;
    for (name) |c| mask |= @as(u32, 1) << @truncate(toLower(c) & 31);
    return mask;
}

pub inline fn toLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c | 0x20 else c;
}

/// Orders two names the way a file list should read: case insensitive, because
/// everything else here ignores case and a list that puts `Zip` above `apple`
/// looks broken rather than precise.
pub fn compareNames(a: []const u8, b: []const u8) std.math.Order {
    const shared = @min(a.len, b.len);
    for (a[0..shared], b[0..shared]) |ca, cb| {
        const la = toLower(ca);
        const lb = toLower(cb);
        if (la != lb) return if (la < lb) .lt else .gt;
    }
    return std.math.order(a.len, b.len);
}

/// Sorts a directory's children by name during the layout pass, while the
/// entry arrays still hold the old indices.
const SiblingOrder = struct {
    names: []const u8,
    offs: []const u32,
    lens: []const u16,

    fn nameOf(self: SiblingOrder, i: u32) []const u8 {
        return self.names[self.offs[i]..][0..self.lens[i]];
    }

    fn lessThan(self: SiblingOrder, a: u32, b: u32) bool {
        return switch (compareNames(self.nameOf(a), self.nameOf(b))) {
            .lt => true,
            .gt => false,
            // Two files in one directory cannot share a name on NTFS, but a
            // half-read table can hand back one twice, and an unstable order
            // would reshuffle the list under whoever scrolls it.
            .eq => a < b,
        };
    }
};

/// Builds a small tree by hand, for tests that should not need a real volume.
pub fn addForTest(index: *Index, parent: u32, name: []const u8, is_dir: bool) !u32 {
    const off = try index.addName(name);
    const self_idx: u32 = @intCast(index.entries.len);
    const i = try index.addEntry(.{
        .name_off = off,
        .parent = if (parent == std.math.maxInt(u32)) self_idx else parent,
        .name_len = @intCast(name.len),
        .bloom = bloomOf(name),
        .path_bloom = 0,
        .is_dir = is_dir,
    });
    try index.computePathBlooms(i);
    return i;
}

test "path walks up to the volume root" {
    const gpa = std.testing.allocator;
    var index = Index.init(gpa);
    defer index.deinit();

    const root = try addForTest(&index, std.math.maxInt(u32), "C:", true);
    const src = try addForTest(&index, root, "src", true);
    const main_zig = try addForTest(&index, src, "main.zig", false);

    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("C:", index.path(root, &buf));
    try std.testing.expectEqualStrings("C:\\src", index.path(src, &buf));
    try std.testing.expectEqualStrings("C:\\src\\main.zig", index.path(main_zig, &buf));
}

test "bloom holds every character of the name" {
    const mask = bloomOf("Main.ZIG");
    for ("main.zig") |c| {
        try std.testing.expect(mask & (@as(u32, 1) << @truncate(c & 31)) != 0);
    }
}

test "path bloom unions every ancestor" {
    const gpa = std.testing.allocator;
    var index = Index.init(gpa);
    defer index.deinit();

    const root = try addForTest(&index, std.math.maxInt(u32), "C:", true);
    const src = try addForTest(&index, root, "src", true);
    const main_zig = try addForTest(&index, src, "main.zig", false);

    const want = bloomOf("C:") | bloomOf("src") | bloomOf("main.zig");
    try std.testing.expectEqual(want, index.entries.slice().items(.path_bloom)[main_zig]);

    // Every character of the full path has to survive the filter.
    var buf: [256]u8 = undefined;
    const full = index.path(main_zig, &buf);
    const got = index.entries.slice().items(.path_bloom)[main_zig];
    for (full) |c| {
        if (c == '\\') continue;
        try std.testing.expect(got & (@as(u32, 1) << @truncate(toLower(c) & 31)) != 0);
    }
}

test "the layout comes out in path order" {
    const gpa = std.testing.allocator;
    var index = Index.init(gpa);
    defer index.deinit();

    const root = try addForTest(&index, std.math.maxInt(u32), "C:", true);
    try index.volumes.append(gpa, .{ .letter = 'C', .root = root });
    // Added in an order no sort would produce by accident, and mixing case so
    // that an ASCII comparison would put Assets last rather than first.
    const zed = try addForTest(&index, root, "zed", true);
    const apps = try addForTest(&index, root, "apps", true);
    _ = try addForTest(&index, zed, "beta.txt", false);
    _ = try addForTest(&index, apps, "gamma.txt", false);
    _ = try addForTest(&index, zed, "Assets.txt", false);
    _ = try addForTest(&index, root, "notes.md", false);

    try index.orderDepthFirst();

    // Walking the entries now walks the drive the way a sorted listing reads,
    // which is what lets a path sort compare two entry numbers.
    var buf: [256]u8 = undefined;
    var last: [256]u8 = undefined;
    var last_len: usize = 0;
    for (0..index.count()) |i| {
        const full = index.path(@intCast(i), &buf);
        if (last_len > 0) {
            try std.testing.expectEqual(std.math.Order.lt, compareNames(last[0..last_len], full));
        }
        @memcpy(last[0..full.len], full);
        last_len = full.len;
    }

    try std.testing.expectEqualStrings("C:\\apps\\gamma.txt", index.path(2, &buf));
    try std.testing.expectEqualStrings("C:\\zed\\Assets.txt", index.path(5, &buf));
}

test "a reordered entry keeps its own size and date" {
    const gpa = std.testing.allocator;
    var index = Index.init(gpa);
    defer index.deinit();

    const root = try addForTest(&index, std.math.maxInt(u32), "C:", true);
    try index.volumes.append(gpa, .{ .letter = 'C', .root = root });
    // Added so that the depth-first walk has to move them: the file under src
    // sorts after notes.md now and before it afterwards.
    const src = try addForTest(&index, root, "src", true);
    _ = try addForTest(&index, root, "notes.md", false);
    const main_zig = try addForTest(&index, src, "main.zig", false);

    {
        const slice = index.entries.slice();
        slice.items(.size)[main_zig] = 4321;
        slice.items(.modified)[main_zig] = 132_223_104_000_000_000;
    }

    try index.orderDepthFirst();

    // Which index it landed on is the layout's business. What it carries is not.
    const moved = index.findPath("C:\\src\\main.zig").?;
    const slice = index.entries.slice();
    try std.testing.expectEqual(@as(u64, 4321), slice.items(.size)[moved]);
    try std.testing.expectEqual(@as(i64, 132_223_104_000_000_000), slice.items(.modified)[moved]);
}

test "a recompute matches what the incremental pass built" {
    const gpa = std.testing.allocator;
    var index = Index.init(gpa);
    defer index.deinit();

    const root = try addForTest(&index, std.math.maxInt(u32), "C:", true);
    const a = try addForTest(&index, root, "alpha", true);
    const b = try addForTest(&index, a, "beta", true);
    _ = try addForTest(&index, b, "gamma.txt", false);

    var before: std.ArrayList(u32) = .empty;
    defer before.deinit(gpa);
    try before.appendSlice(gpa, index.entries.slice().items(.path_bloom));

    try index.refreshLayout();
    try std.testing.expectEqualSlices(u32, before.items, index.entries.slice().items(.path_bloom));
}
