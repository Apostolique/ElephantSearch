//! Reads every file and directory name off an NTFS volume by walking the MFT
//! through FSCTL_ENUM_USN_DATA. One pass over the volume metadata, no directory
//! traversal, no stat calls. Opening the volume handle needs administrator
//! rights.

const std = @import("std");
const w = @import("win32.zig");
const idx = @import("index.zig");
const Index = idx.Index;
const volume = @import("volume.zig");

pub const Error = volume.Error;

pub const ScanStats = struct {
    entries: u32 = 0,
    name_bytes: u64 = 0,
    millis: u64 = 0,
};

pub const ntfsDrives = volume.ntfsDrives;

/// What a saved index can still be used for.
pub const Resume = enum {
    /// Every drive can be walked forward from where the cache left off.
    ready,
    /// A journal was recreated or has thrown away the records the cache needs,
    /// or the drives are not the same set any more. Reading them again is the
    /// only correct answer.
    behind,
    /// A drive would not open for want of administrator rights, so nothing can
    /// be checked or caught up. Reading the drives again would fail the same
    /// way, which leaves the cache as it was saved as the best answer there is.
    denied,
};

fn canResume(reader: volume.Reader, vol: idx.Volume) Resume {
    const found = reader.journal(vol.letter) catch |e| return switch (e) {
        // A service that stopped answering says nothing about the drive, and
        // throwing the cache away over it would leave nothing to search.
        error.AccessDenied, error.ServiceFailed => .denied,
        else => .behind,
    };
    const j = found orelse return .behind;
    if (j.id != vol.journal_id or vol.journal_id == 0) return .behind;
    return if (vol.next_usn >= j.oldest() and vol.next_usn <= j.next) .ready else .behind;
}

/// Whether a cached index still stands for this machine: the same set of NTFS
/// drives, and every one of them close enough behind to catch up. A cache with
/// a drive missing looks exactly like a complete one to a search, so the check
/// has to happen before anybody trusts it.
pub fn resumable(index: *const Index, reader: volume.Reader) Resume {
    if (index.volumes.items.len == 0) return .behind;

    var state: Resume = .ready;
    for (index.volumes.items) |vol| {
        switch (canResume(reader, vol)) {
            .ready => {},
            .behind => if (state == .ready) {
                state = .behind;
            },
            .denied => return .denied,
        }
    }
    if (state != .ready) return state;

    var letter_buf: [26]u8 = undefined;
    const present = ntfsDrives(&letter_buf);
    if (present.len != index.volumes.items.len) return .behind;
    for (present) |letter| {
        for (index.volumes.items) |vol| {
            if (vol.letter == letter) break;
        } else return .behind;
    }
    return .ready;
}

pub const Stat = struct {
    size: u64,
    modified: i64,
};

test "a file on disk reports a size and a date" {
    const gpa = std.testing.allocator;
    const found = statPath(gpa, "build.zig") orelse return error.NoSuchFile;
    try std.testing.expect(found.size > 0);
    // Anything real was modified after 2001, which is 12.6e16 ticks in.
    try std.testing.expect(found.modified > 126_000_000_000_000_000);
}

test "a path that is not there reports nothing" {
    try std.testing.expect(statPath(std.testing.allocator, "no_such_file_xyzzy") == null);
    try std.testing.expect(statPath(std.testing.allocator, "C:\\no_such_dir_xyzzy\\f") == null);
}

/// Size and date straight from the file system, for the handful of rows on
/// screen. The background table pass answers in bulk and takes a while to get
/// there, while this is immediate and always current, so display uses it and
/// falls back to the stored fields only when the file has since gone.
pub fn statPath(gpa: std.mem.Allocator, path: []const u8) ?Stat {
    var wide: std.ArrayList(u8) = .empty;
    defer wide.deinit(gpa);

    // Paths off the table routinely pass 260 characters, which the plain form
    // of the call refuses. The prefix lifts that, but only for absolute paths.
    const absolute = path.len > 2 and path[1] == ':';
    if (absolute) wide.appendSlice(gpa, "\\\\?\\") catch return null;
    wide.appendSlice(gpa, path) catch return null;

    const utf16 = std.unicode.wtf8ToWtf16LeAllocZ(gpa, wide.items) catch return null;
    defer gpa.free(utf16);

    var data: w.FileAttributeData = undefined;
    if (w.GetFileAttributesExW(utf16, w.GetFileExInfoStandard, &data) == 0) return null;
    return .{ .size = data.size(), .modified = data.written.ticks() };
}

/// Adds every entry on `letter` to `index` and links each one to its parent.
pub fn scanVolume(index: *Index, reader: volume.Reader, letter: u8) Error!ScanStats {
    const timer = w.Timer.start();
    const gpa = index.gpa;
    const first_entry: u32 = index.count();

    // Asked before the listing, so whatever changes while the volume is being
    // read is still ahead of the saved position and gets replayed.
    const journal = try reader.journal(letter);

    var scan: Scan = .{ .index = index, .first_entry = first_entry };
    defer scan.parent_frns.deinit(gpa);
    scan.vol = .{ .letter = letter, .root = first_entry };
    errdefer scan.vol.frn_map.deinit(gpa);
    if (journal) |j| {
        scan.vol.journal_id = j.id;
        scan.vol.next_usn = j.next;
    }

    // Volume root, named "C:" so a full path prints as C:\dir\file.
    const root_name = [_]u8{ letter, ':' };
    const root_off = try index.addName(&root_name);
    const root_idx = try index.addEntry(.{
        .name_off = root_off,
        .parent = first_entry,
        .name_len = root_name.len,
        .bloom = idx.bloomOf(&root_name),
        .path_bloom = 0,
        .is_dir = true,
    });
    std.debug.assert(root_idx == first_entry);
    try scan.parent_frns.append(gpa, 0); // root has no parent

    try reader.enumerate(letter, .{ .ctx = &scan, .batch = Scan.batch });

    // Parent references are file reference numbers, and a child can appear
    // before its parent, so they get resolved after the whole volume is read.
    // Anything whose parent never showed up hangs off the volume root.
    const parents = index.entries.slice().items(.parent);
    for (scan.parent_frns.items[1..], first_entry + 1..) |frn, i| {
        parents[i] = scan.vol.frn_map.get(frn) orelse first_entry;
    }

    // Path blooms need the parent links, so they come last.
    try index.computePathBlooms(first_entry);

    try index.volumes.append(gpa, scan.vol);
    scan.stats.millis = timer.readMillis();
    return scan.stats;
}

const Scan = struct {
    index: *Index,
    first_entry: u32,
    vol: idx.Volume = undefined,
    parent_frns: std.ArrayList(u64) = .empty,
    stats: ScanStats = .{},

    fn batch(ctx: *anyopaque, bytes: []const u8) Error!void {
        const self: *Scan = @ptrCast(@alignCast(ctx));
        const index = self.index;
        const gpa = index.gpa;
        var it: volume.NameIter = .{ .bytes = bytes };
        while (try it.next()) |n| {
            const off = try index.addName(n.name);
            const e = try index.addEntry(.{
                .name_off = off,
                .parent = self.first_entry,
                .name_len = @intCast(n.name.len),
                .bloom = idx.bloomOf(n.name),
                .path_bloom = 0,
                .is_dir = n.is_dir,
            });
            try self.parent_frns.append(gpa, n.parent_frn);
            try self.vol.frn_map.put(gpa, n.frn, e);
            self.stats.entries += 1;
            self.stats.name_bytes += n.name.len;
        }
    }
};

const fake = @import("fake.zig");

test "a made up volume comes out as a tree" {
    const gpa = std.testing.allocator;
    var index = Index.init(gpa);
    defer index.deinit();

    const reader = try fake.Fake.open(gpa, .{ .files = 25 });
    defer reader.close();

    const stats = try scanVolume(&index, reader, 'C');
    try std.testing.expectEqual(@as(u32, 25 + fake.directories), stats.entries);
    try std.testing.expectEqual(fake.journal_id, index.volumes.items[0].journal_id);
    try std.testing.expectEqual(fake.journal_start, index.volumes.items[0].next_usn);

    try index.orderDepthFirst();
    var buf: [256]u8 = undefined;
    const at = index.findPath("C:\\dir3\\file13.txt") orelse return error.NotFound;
    try std.testing.expectEqualStrings("C:\\dir3\\file13.txt", index.path(at, &buf));
    try std.testing.expect(index.isDir(index.findPath("C:\\dir9") orelse return error.NotFound));
}

test "a saved index resumes only while its journal still reaches back far enough" {
    const gpa = std.testing.allocator;
    const reader = try fake.Fake.open(gpa, .{ .files = 1, .denied = 'Q' });
    defer reader.close();

    var vol: idx.Volume = .{ .letter = 'C', .root = 0, .journal_id = fake.journal_id, .next_usn = fake.journal_start };
    try std.testing.expectEqual(Resume.ready, canResume(reader, vol));
    vol.next_usn = fake.journal_start + 1;
    try std.testing.expectEqual(Resume.behind, canResume(reader, vol));
    vol.next_usn = fake.journal_start;
    vol.journal_id = 1;
    try std.testing.expectEqual(Resume.behind, canResume(reader, vol));
    vol.letter = 'Q';
    try std.testing.expectEqual(Resume.denied, canResume(reader, vol));
}
