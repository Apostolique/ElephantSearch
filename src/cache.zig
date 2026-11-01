//! Saves the finished index to disk so the next run does not have to build it
//! again.
//!
//! Reading a drive's names costs seconds and reading its file records costs a
//! lot more, and almost none of it changes between two runs a minute apart.
//! Every volume already records the journal it was read from and how far it
//! got, so a loaded index only has to be walked forward from there. When the
//! journal has moved on too far to bridge, the cache is thrown away and the
//! drive is read from scratch, which is the only safe answer.
//!
//! The layout work is split from the file work: `write` and `read` take a sink
//! and a source, so a whole index can be round tripped through memory in a test
//! without touching a disk or needing a privilege.

const std = @import("std");
const w = @import("win32.zig");
const idx = @import("index.zig");

const Index = idx.Index;

/// Bumped whenever the layout below changes, which retires older files rather
/// than trying to read them. The order the entries are in counts as layout: a
/// file written before the depth-first pass sorted siblings by name holds them
/// in the order the master file table handed them over, and a path sort reading
/// entry numbers off that would come out shuffled inside every directory.
const magic = "ELEPHANT";
const version: u32 = 3;

pub const Error = error{
    NotACache,
    WrongVersion,
    Truncated,
    Corrupt,
} || std.mem.Allocator.Error;

const Header = extern struct {
    magic: [8]u8,
    version: u32,
    entries: u32,
    names: u64,
    volumes: u32,
    ordered: u32,
};

const VolumeHeader = extern struct {
    letter: u8,
    _pad: [3]u8 = .{ 0, 0, 0 },
    root: u32,
    journal_id: u64,
    next_usn: i64,
    mappings: u32,
    _tail: u32 = 0,
};

// File references and the entries they point at are written as two blocks
// rather than as a run of pairs. One call each moves them, and a pair would
// carry four bytes of padding per entry for nothing.

// ---- writing ----

/// Writes the whole index to `sink`, which needs one `writeAll` method.
pub fn write(sink: anytype, index: *const Index) !void {
    const slice = index.entries.slice();
    const n = index.count();

    try put(sink, Header{
        .magic = magic.*,
        .version = version,
        .entries = n,
        .names = index.names.items.len,
        .volumes = @intCast(index.volumes.items.len),
        .ordered = index.ordered,
    });

    try sink.writeAll(std.mem.sliceAsBytes(slice.items(.name_off)));
    try sink.writeAll(std.mem.sliceAsBytes(slice.items(.parent)));
    try sink.writeAll(std.mem.sliceAsBytes(slice.items(.name_len)));
    try sink.writeAll(std.mem.sliceAsBytes(slice.items(.bloom)));
    try sink.writeAll(std.mem.sliceAsBytes(slice.items(.path_bloom)));
    try sink.writeAll(std.mem.sliceAsBytes(slice.items(.size)));
    try sink.writeAll(std.mem.sliceAsBytes(slice.items(.modified)));
    try sink.writeAll(std.mem.sliceAsBytes(slice.items(.is_dir)));
    try sink.writeAll(index.names.items);

    const gpa = index.gpa;
    for (index.volumes.items) |*vol| {
        const count = vol.frn_map.count();
        try put(sink, VolumeHeader{
            .letter = vol.letter,
            .root = vol.root,
            .journal_id = vol.journal_id,
            .next_usn = vol.next_usn,
            .mappings = count,
        });

        const frns = try gpa.alloc(u64, count);
        defer gpa.free(frns);
        const entries = try gpa.alloc(u32, count);
        defer gpa.free(entries);

        var at: usize = 0;
        var it = vol.frn_map.iterator();
        while (it.next()) |kv| : (at += 1) {
            frns[at] = kv.key_ptr.*;
            entries[at] = kv.value_ptr.*;
        }

        try sink.writeAll(std.mem.sliceAsBytes(frns));
        try sink.writeAll(std.mem.sliceAsBytes(entries));
    }
}

fn put(sink: anytype, value: anytype) !void {
    try sink.writeAll(std.mem.asBytes(&value));
}

// ---- reading ----

/// Rebuilds `index` from `source`, which needs one `readAll` method filling a
/// buffer in order. The index must be empty going in, and is left empty when
/// this fails, so a rejected cache costs nothing but a full scan.
pub fn read(source: anytype, index: *Index) !void {
    errdefer forget(index);

    const head = try take(source, Header);
    if (!std.mem.eql(u8, &head.magic, magic)) return error.NotACache;
    if (head.version != version) return error.WrongVersion;
    if (head.ordered > head.entries) return error.Corrupt;

    const gpa = index.gpa;
    const n = head.entries;
    try index.entries.resize(gpa, n);
    const slice = index.entries.slice();

    try source.readAll(std.mem.sliceAsBytes(slice.items(.name_off)));
    try source.readAll(std.mem.sliceAsBytes(slice.items(.parent)));
    try source.readAll(std.mem.sliceAsBytes(slice.items(.name_len)));
    try source.readAll(std.mem.sliceAsBytes(slice.items(.bloom)));
    try source.readAll(std.mem.sliceAsBytes(slice.items(.path_bloom)));
    try source.readAll(std.mem.sliceAsBytes(slice.items(.size)));
    try source.readAll(std.mem.sliceAsBytes(slice.items(.modified)));
    try source.readAll(std.mem.sliceAsBytes(slice.items(.is_dir)));

    try index.names.resize(gpa, @intCast(head.names));
    try source.readAll(index.names.items);

    for (0..head.volumes) |_| {
        const vh = try take(source, VolumeHeader);
        if (vh.root >= n) return error.Corrupt;

        var vol: idx.Volume = .{
            .letter = vh.letter,
            .root = vh.root,
            .journal_id = vh.journal_id,
            .next_usn = vh.next_usn,
        };
        errdefer vol.frn_map.deinit(gpa);

        const frns = try gpa.alloc(u64, vh.mappings);
        defer gpa.free(frns);
        const entries = try gpa.alloc(u32, vh.mappings);
        defer gpa.free(entries);

        try source.readAll(std.mem.sliceAsBytes(frns));
        try source.readAll(std.mem.sliceAsBytes(entries));

        try vol.frn_map.ensureTotalCapacity(gpa, vh.mappings);
        for (frns, entries) |frn, entry| {
            if (entry >= n) return error.Corrupt;
            vol.frn_map.putAssumeCapacity(frn, entry);
        }
        try index.volumes.append(gpa, vol);
    }

    index.ordered = head.ordered;
    try check(index);
}

fn take(source: anytype, comptime T: type) !T {
    var value: T = undefined;
    try source.readAll(std.mem.asBytes(&value));
    return value;
}

/// A cache is just bytes on disk that anything could have written over, and
/// every field here is used as an index into something. One pass up front is
/// cheaper than a bounds check in the middle of every search.
fn check(index: *const Index) !void {
    const slice = index.entries.slice();
    const n = index.count();
    const names = index.names.items.len;

    const parents = slice.items(.parent);
    const offs = slice.items(.name_off);
    const lens = slice.items(.name_len);

    for (0..n) |i| {
        if (parents[i] >= n) return error.Corrupt;
        if (@as(usize, offs[i]) + lens[i] > names) return error.Corrupt;
    }
    for (index.volumes.items) |vol| {
        if (vol.root >= n) return error.Corrupt;
        // A volume root is its own parent, which is what ends a path walk.
        if (parents[vol.root] != vol.root) return error.Corrupt;
    }
}

/// Empties an index again, for a cache that loaded but turned out to be too
/// far behind to catch up.
pub fn forget(index: *Index) void {
    for (index.volumes.items) |*v| v.frn_map.deinit(index.gpa);
    index.volumes.clearRetainingCapacity();
    index.entries.shrinkRetainingCapacity(0);
    index.names.clearRetainingCapacity();
    index.ordered = 0;
}

// ---- files ----

const Writer = struct {
    handle: w.HANDLE,

    fn writeAll(self: Writer, bytes: []const u8) !void {
        var done: usize = 0;
        while (done < bytes.len) {
            var wrote: w.DWORD = 0;
            const want: w.DWORD = @intCast(@min(bytes.len - done, 1 << 24));
            if (w.WriteFile(self.handle, bytes.ptr + done, want, &wrote, null) == 0) {
                return error.WriteFailed;
            }
            if (wrote == 0) return error.WriteFailed;
            done += wrote;
        }
    }
};

const Reader = struct {
    handle: w.HANDLE,

    fn readAll(self: Reader, buf: []u8) !void {
        var done: usize = 0;
        while (done < buf.len) {
            var got: w.DWORD = 0;
            const want: w.DWORD = @intCast(@min(buf.len - done, 1 << 24));
            if (w.ReadFile(self.handle, buf.ptr + done, want, &got, null) == 0) {
                return error.Truncated;
            }
            if (got == 0) return error.Truncated;
            done += got;
        }
    }
};

/// `%LOCALAPPDATA%\ElephantSearch\index.cache`, as UTF-16 with a terminator.
/// Returns null when there is no local application data to put it in.
pub fn defaultPath(gpa: std.mem.Allocator) ?[:0]u16 {
    return pathNamed(gpa, std.unicode.utf8ToUtf16LeStringLiteral("\\index.cache"));
}

/// The same directory under a different file name, for anything else this
/// program keeps per user. Tests use it so that running them never touches
/// what a real run left behind.
pub fn pathNamed(gpa: std.mem.Allocator, file: [:0]const u16) ?[:0]u16 {
    const name = std.unicode.utf8ToUtf16LeStringLiteral("LOCALAPPDATA");
    const needed = w.GetEnvironmentVariableW(name, null, 0);
    if (needed == 0) return null;

    const suffix = std.unicode.utf8ToUtf16LeStringLiteral("\\ElephantSearch");

    // Whatever comes back has to be freed as a whole allocation, so the path is
    // grown in a list rather than carved out of one oversized buffer.
    var dir: std.ArrayList(u16) = .empty;
    defer dir.deinit(gpa);
    dir.resize(gpa, needed) catch return null;

    // The size asked for counts the terminator, the size returned does not.
    const got = w.GetEnvironmentVariableW(name, dir.items.ptr, needed);
    if (got == 0 or got >= needed) return null;
    dir.shrinkRetainingCapacity(got);
    dir.appendSlice(gpa, suffix) catch return null;

    const terminated = dir.toOwnedSliceSentinel(gpa, 0) catch return null;
    defer gpa.free(terminated);
    // Ours to make, and already being there is a success.
    _ = w.CreateDirectoryW(terminated.ptr, null);

    var full: std.ArrayList(u16) = .empty;
    defer full.deinit(gpa);
    full.appendSlice(gpa, terminated) catch return null;
    full.appendSlice(gpa, file) catch return null;
    return full.toOwnedSliceSentinel(gpa, 0) catch null;
}

/// Writes to a neighbouring file and renames it over the real one, so an
/// interrupted save leaves the previous cache rather than half of a new one.
pub fn save(index: *const Index, path: [:0]const u16, gpa: std.mem.Allocator) !void {
    const temp = try gpa.allocSentinel(u16, path.len + 4, 0);
    defer gpa.free(temp);
    @memcpy(temp[0..path.len], path);
    @memcpy(temp[path.len..][0..4], std.unicode.utf8ToUtf16LeStringLiteral(".new"));

    const handle = w.CreateFileW(
        temp.ptr,
        w.GENERIC_WRITE,
        0,
        null,
        w.CREATE_ALWAYS,
        w.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (handle == w.INVALID_HANDLE_VALUE) return error.WriteFailed;

    write(Writer{ .handle = handle }, index) catch |e| {
        _ = w.CloseHandle(handle);
        _ = w.DeleteFileW(temp.ptr);
        return e;
    };
    _ = w.CloseHandle(handle);

    if (w.MoveFileExW(temp.ptr, path.ptr, w.MOVEFILE_REPLACE_EXISTING) == 0) {
        _ = w.DeleteFileW(temp.ptr);
        return error.WriteFailed;
    }
}

/// Fills `index` from the file at `path` and returns when the file was last
/// written, as a file time.
pub fn load(index: *Index, path: [:0]const u16) !i64 {
    const handle = w.CreateFileW(
        path.ptr,
        w.GENERIC_READ,
        w.FILE_SHARE_READ,
        null,
        w.OPEN_EXISTING,
        w.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (handle == w.INVALID_HANDLE_VALUE) return error.NotACache;
    defer _ = w.CloseHandle(handle);

    try read(Reader{ .handle = handle }, index);

    var info: w.FileAttributeData = undefined;
    if (w.GetFileAttributesExW(path.ptr, w.GetFileExInfoStandard, &info) == 0) return 0;
    return info.written.ticks();
}

pub fn discard(path: [:0]const u16) void {
    _ = w.DeleteFileW(path.ptr);
}

// ---- tests ----

const testing = std.testing;

/// Collects everything written, so a whole index can be round tripped without
/// a file anywhere.
const MemorySink = struct {
    bytes: *std.ArrayList(u8),
    gpa: std.mem.Allocator,

    fn writeAll(self: MemorySink, data: []const u8) !void {
        try self.bytes.appendSlice(self.gpa, data);
    }
};

const MemorySource = struct {
    bytes: []const u8,
    at: *usize,

    fn readAll(self: MemorySource, buf: []u8) !void {
        if (self.at.* + buf.len > self.bytes.len) return error.Truncated;
        @memcpy(buf, self.bytes[self.at.*..][0..buf.len]);
        self.at.* += buf.len;
    }
};

fn sampleIndex(index: *Index) !void {
    const root = try idx.addForTest(index, std.math.maxInt(u32), "C:", true);
    try index.volumes.append(index.gpa, .{
        .letter = 'C',
        .root = root,
        .journal_id = 0xABCD_1234,
        .next_usn = 987654,
    });
    const src = try idx.addForTest(index, root, "src", true);
    _ = try idx.addForTest(index, src, "main.zig", false);
    _ = try idx.addForTest(index, root, "notes.md", false);
    try index.orderDepthFirst();

    // Laying the tree out moves entries, so these are found again rather than
    // held from before it ran.
    const main_zig = index.findPath("C:\\src\\main.zig").?;
    const slice = index.entries.slice();
    slice.items(.size)[main_zig] = 4321;
    slice.items(.modified)[main_zig] = 133_485_408_000_000_000;

    var vol = &index.volumes.items[0];
    try vol.frn_map.put(index.gpa, 0x5000_0000_0001, vol.root);
    try vol.frn_map.put(index.gpa, 0x5000_0000_0002, main_zig);
}

fn roundTrip(gpa: std.mem.Allocator, from: *const Index, into: *Index) !void {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try write(MemorySink{ .bytes = &bytes, .gpa = gpa }, from);

    var at: usize = 0;
    try read(MemorySource{ .bytes = bytes.items, .at = &at }, into);
    try testing.expectEqual(bytes.items.len, at);
}

test "an index survives a round trip" {
    const gpa = testing.allocator;
    var original = Index.init(gpa);
    defer original.deinit();
    try sampleIndex(&original);

    var restored = Index.init(gpa);
    defer restored.deinit();
    try roundTrip(gpa, &original, &restored);

    try testing.expectEqual(original.count(), restored.count());
    try testing.expectEqual(original.ordered, restored.ordered);

    var a: [256]u8 = undefined;
    var b: [256]u8 = undefined;
    for (0..original.count()) |i| {
        const at: u32 = @intCast(i);
        try testing.expectEqualStrings(original.path(at, &a), restored.path(at, &b));
        try testing.expectEqual(original.isDir(at), restored.isDir(at));
    }
}

test "sizes and dates come back with everything else" {
    const gpa = testing.allocator;
    var original = Index.init(gpa);
    defer original.deinit();
    try sampleIndex(&original);

    var restored = Index.init(gpa);
    defer restored.deinit();
    try roundTrip(gpa, &original, &restored);

    const found = restored.findPath("C:\\src\\main.zig").?;
    const slice = restored.entries.slice();
    try testing.expectEqual(@as(u64, 4321), slice.items(.size)[found]);
    try testing.expectEqual(@as(i64, 133_485_408_000_000_000), slice.items(.modified)[found]);
}

test "a volume keeps its journal position, which is what avoids a rescan" {
    const gpa = testing.allocator;
    var original = Index.init(gpa);
    defer original.deinit();
    try sampleIndex(&original);

    var restored = Index.init(gpa);
    defer restored.deinit();
    try roundTrip(gpa, &original, &restored);

    try testing.expectEqual(@as(usize, 1), restored.volumes.items.len);
    const vol = restored.volumes.items[0];
    try testing.expectEqual(@as(u8, 'C'), vol.letter);
    try testing.expectEqual(@as(u64, 0xABCD_1234), vol.journal_id);
    try testing.expectEqual(@as(i64, 987654), vol.next_usn);
    try testing.expectEqual(@as(u32, 2), vol.frn_map.count());
    // The journal reports file references, so this map is what turns one back
    // into an entry after a load.
    try testing.expectEqual(restored.findPath("C:\\src\\main.zig").?, vol.frn_map.get(0x5000_0000_0002).?);
}

test "a searcher works the same against a restored index" {
    const gpa = testing.allocator;
    var original = Index.init(gpa);
    defer original.deinit();
    try sampleIndex(&original);

    var restored = Index.init(gpa);
    defer restored.deinit();
    try roundTrip(gpa, &original, &restored);

    const search = @import("search.zig");
    var searcher = search.Searcher.init(gpa, &restored);
    defer searcher.deinit();

    const hits = try searcher.search("mainzg", 10);
    try testing.expectEqual(@as(usize, 1), hits.len);
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("C:\\src\\main.zig", restored.path(hits[0].entry, &buf));
}

test "the cache lands somewhere with a name" {
    const gpa = testing.allocator;
    const path = defaultPath(gpa) orelse return error.NoLocalAppData;
    defer gpa.free(path);

    var utf8: [1024]u8 = undefined;
    const n = std.unicode.wtf16LeToWtf8(&utf8, path);
    const text = utf8[0..n];
    try testing.expect(std.mem.endsWith(u8, text, "\\ElephantSearch\\index.cache"));
    // An absolute path, so the drive is on the front rather than the cwd.
    try testing.expect(text.len > 3 and text[1] == ':');
}

test "saving and loading a real file gives the index back" {
    const gpa = testing.allocator;
    // Never the real path. This test deletes what it writes, and a run's own
    // cache is not something a test run is allowed to throw away.
    const scratch = std.unicode.utf8ToUtf16LeStringLiteral("\\index.cache.test");
    const path = pathNamed(gpa, scratch) orelse return error.NoLocalAppData;
    defer gpa.free(path);
    defer discard(path);

    var original = Index.init(gpa);
    defer original.deinit();
    try sampleIndex(&original);
    try save(&original, path, gpa);

    var restored = Index.init(gpa);
    defer restored.deinit();
    const saved = try load(&restored, path);
    // Just written, so after 2001 like anything real.
    try testing.expect(saved > 126_000_000_000_000_000);

    try testing.expectEqual(original.count(), restored.count());
    var buf: [256]u8 = undefined;
    const found = restored.findPath("C:\\src\\main.zig").?;
    try testing.expectEqualStrings("C:\\src\\main.zig", restored.path(found, &buf));
}

test "something that is not a cache is refused" {
    const gpa = testing.allocator;
    var index = Index.init(gpa);
    defer index.deinit();

    var at: usize = 0;
    const junk = "not an elephant at all, just some bytes" ** 4;
    try testing.expectError(error.NotACache, read(MemorySource{ .bytes = junk, .at = &at }, &index));
    try testing.expectEqual(@as(u32, 0), index.count());
}

test "a cache cut short is refused rather than half loaded" {
    const gpa = testing.allocator;
    var original = Index.init(gpa);
    defer original.deinit();
    try sampleIndex(&original);

    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try write(MemorySink{ .bytes = &bytes, .gpa = gpa }, &original);

    var index = Index.init(gpa);
    defer index.deinit();
    var at: usize = 0;
    const half = bytes.items[0 .. bytes.items.len / 2];
    try testing.expectError(error.Truncated, read(MemorySource{ .bytes = half, .at = &at }, &index));
    try testing.expectEqual(@as(u32, 0), index.count());
}

test "a parent pointing off the end is caught before anything uses it" {
    const gpa = testing.allocator;
    var original = Index.init(gpa);
    defer original.deinit();
    try sampleIndex(&original);

    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try write(MemorySink{ .bytes = &bytes, .gpa = gpa }, &original);

    // The parent array follows the header and the name offsets.
    const parents_at = @sizeOf(Header) + original.count() * @sizeOf(u32);
    std.mem.writeInt(u32, bytes.items[parents_at..][0..4], 9999, .little);

    var index = Index.init(gpa);
    defer index.deinit();
    var at: usize = 0;
    try testing.expectError(error.Corrupt, read(MemorySource{ .bytes = bytes.items, .at = &at }, &index));
    try testing.expectEqual(@as(u32, 0), index.count());
}

test "a name running past the blob is caught too" {
    const gpa = testing.allocator;
    var original = Index.init(gpa);
    defer original.deinit();
    try sampleIndex(&original);

    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try write(MemorySink{ .bytes = &bytes, .gpa = gpa }, &original);

    std.mem.writeInt(u32, bytes.items[@sizeOf(Header)..][0..4], 0xFFFF, .little);

    var index = Index.init(gpa);
    defer index.deinit();
    var at: usize = 0;
    try testing.expectError(error.Corrupt, read(MemorySource{ .bytes = bytes.items, .at = &at }, &index));
}
