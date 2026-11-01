//! Keeps the index current from the NTFS change journal. One thread per volume
//! reads FSCTL_READ_USN_JOURNAL and parks the records in a queue, and the
//! search thread applies them right before it runs a query. Nothing mutates the
//! index while a search is walking it, so no lock sits in the hot path.
//!
//! Renaming a directory needs no extra work: paths come from parent links, so
//! every file under it follows along.

const std = @import("std");
const w = @import("win32.zig");
const idx = @import("index.zig");
const Index = idx.Index;
const volume = @import("volume.zig");

/// How long a change waits before the next query picks it up.
const poll_ms: u32 = 200;

const Change = struct {
    frn: u64,
    parent_frn: u64,
    reason: u32,
    name_off: u32,
    name_len: u16,
    volume: u16,
    is_dir: bool,
};

pub const Monitor = struct {
    gpa: std.mem.Allocator,
    index: *Index,
    source: volume.Source,
    lock: w.Lock = .{},
    pending: std.ArrayList(Change) = .empty,
    names: std.ArrayList(u8) = .empty,
    workers: std.ArrayList(std.Thread) = .empty,
    running: std.atomic.Value(bool) = .init(true),
    /// Set when a journal wrapped past our position, which means records were
    /// missed and only a rescan can put the index back in sync.
    lost: std.atomic.Value(bool) = .init(false),
    applied: u64 = 0,

    pub fn init(gpa: std.mem.Allocator, index: *Index, source: volume.Source) Monitor {
        return .{ .gpa = gpa, .index = index, .source = source };
    }

    pub fn deinit(self: *Monitor) void {
        self.stop();
        self.pending.deinit(self.gpa);
        self.names.deinit(self.gpa);
        self.workers.deinit(self.gpa);
    }

    /// Starts a watcher for every volume that has an active journal. Returns
    /// how many are being watched.
    pub fn start(self: *Monitor) !usize {
        for (self.index.volumes.items, 0..) |*vol, i| {
            if (vol.journal_id == 0) continue;
            const t = std.Thread.spawn(.{}, watch, .{ self, i }) catch continue;
            try self.workers.append(self.gpa, t);
        }
        return self.workers.items.len;
    }

    pub fn stop(self: *Monitor) void {
        if (self.workers.items.len == 0) return;
        self.running.store(false, .release);
        for (self.workers.items) |t| t.join();
        self.workers.clearRetainingCapacity();
    }

    /// Whether a watcher has queued anything since the last drain. Cheap enough
    /// to ask on an idle timer, so a change can redraw without a keystroke.
    pub fn hasPending(self: *Monitor) bool {
        self.lock.acquire();
        defer self.lock.release();
        return self.pending.items.len > 0;
    }

    /// Applies everything the watchers have queued. Call it from the thread
    /// that runs searches, never while one is in flight.
    pub fn drain(self: *Monitor) !usize {
        self.lock.acquire();
        const changes = self.pending.toOwnedSlice(self.gpa) catch |e| {
            self.lock.release();
            return e;
        };
        const names = self.names.toOwnedSlice(self.gpa) catch |e| {
            self.lock.release();
            self.gpa.free(changes);
            return e;
        };
        self.lock.release();
        defer self.gpa.free(changes);
        defer self.gpa.free(names);

        // Applying can append entries, which moves every array. The background
        // size pass holds this while it writes into them.
        self.index.growing.acquire();
        defer self.index.growing.release();

        for (changes) |c| {
            try self.apply(c, names[c.name_off..][0..c.name_len]);
        }
        self.applied += changes.len;
        return changes.len;
    }

    fn apply(self: *Monitor, c: Change, name: []const u8) !void {
        const vol = &self.index.volumes.items[c.volume];

        // A reason mask accumulates over a file's open session, so a delete can
        // arrive carrying the create bit too. Deletion wins.
        if (c.reason & w.USN_REASON_FILE_DELETE != 0) {
            if (vol.frn_map.fetchRemove(c.frn)) |kv| self.index.kill(kv.value);
            return;
        }

        // The old-name record of a rename only says what the file used to be
        // called. The new-name record that follows carries the result.
        const renaming_away = c.reason & w.USN_REASON_RENAME_OLD_NAME != 0 and
            c.reason & w.USN_REASON_RENAME_NEW_NAME == 0;
        if (renaming_away) return;

        const interesting = w.USN_REASON_FILE_CREATE | w.USN_REASON_RENAME_NEW_NAME;
        if (c.reason & interesting == 0) return;

        const parent = vol.frn_map.get(c.parent_frn) orelse vol.root;
        if (vol.frn_map.get(c.frn)) |existing| {
            try self.index.rename(existing, name, parent);
        } else {
            const off = try self.index.addName(name);
            const parent_bloom = self.index.entries.slice().items(.path_bloom)[parent];
            const e = try self.index.addEntry(.{
                .name_off = off,
                .parent = parent,
                .name_len = @intCast(name.len),
                .bloom = idx.bloomOf(name),
                .path_bloom = idx.bloomOf(name) | parent_bloom,
                .is_dir = c.is_dir,
            });
            try vol.frn_map.put(self.gpa, c.frn, e);
        }
    }

    fn queue(self: *Monitor, c: Change, name: []const u8) !void {
        self.lock.acquire();
        defer self.lock.release();
        var copy = c;
        copy.name_off = @intCast(self.names.items.len);
        copy.name_len = @intCast(name.len);
        try self.names.appendSlice(self.gpa, name);
        try self.pending.append(self.gpa, copy);
    }
};

/// How long a watcher waits before asking a service that stopped answering
/// again. The journal keeps the changes in the meantime.
const reconnect_ms: u32 = 2000;

const Watch = struct {
    m: *Monitor,
    vol_index: usize,

    fn batch(ctx: *anyopaque, bytes: []const u8) volume.Error!void {
        const self: *Watch = @ptrCast(@alignCast(ctx));
        var it: volume.NameIter = .{ .bytes = bytes };
        while (try it.next()) |n| {
            self.m.queue(.{
                .frn = n.frn,
                .parent_frn = n.parent_frn,
                .reason = n.reason,
                .name_off = 0,
                .name_len = 0,
                .volume = @intCast(self.vol_index),
                .is_dir = n.is_dir,
            }, n.name) catch return error.OutOfMemory;
        }
    }
};

fn watch(m: *Monitor, vol_index: usize) void {
    const vol = &m.index.volumes.items[vol_index];
    const letter = vol.letter;
    const journal_id = vol.journal_id;
    var next_usn = vol.next_usn;

    var reader: ?volume.Reader = null;
    defer if (reader) |r| r.close();
    var ctx: Watch = .{ .m = m, .vol_index = vol_index };

    while (m.running.load(.acquire)) {
        const r = reader orelse m.source.open(m.gpa) catch |e| switch (e) {
            error.ServiceFailed => {
                w.Sleep(reconnect_ms);
                continue;
            },
            else => return,
        };
        reader = r;

        const after = r.changes(letter, journal_id, next_usn, .{ .ctx = &ctx, .batch = Watch.batch }) catch |e| switch (e) {
            error.JournalLost => {
                m.lost.store(true, .release);
                return;
            },
            // Whatever was queued from the read that broke off is queued
            // again by the next one, and applying a change twice lands in the
            // same place.
            error.ServiceFailed => {
                r.close();
                reader = null;
                w.Sleep(reconnect_ms);
                continue;
            },
            error.OutOfMemory, error.Stopped => return,
            else => {
                w.Sleep(poll_ms);
                continue;
            },
        };
        if (after == next_usn) {
            w.Sleep(poll_ms);
            continue;
        }
        next_usn = after;
        // Kept on the volume so a saved index knows where to pick the journal
        // up next time. Only ever read once the watchers have been joined.
        vol.next_usn = next_usn;
    }
}

const fake = @import("fake.zig");
const ntfs = @import("ntfs.zig");

/// Entries the journal adds sit past every subtree, where a path lookup does
/// not reach, so the test looks for the name itself.
fn named(index: *const Index, name: []const u8) ?u32 {
    var i: u32 = 0;
    while (i < index.count()) : (i += 1) {
        if (std.mem.eql(u8, index.nameOf(i), name)) return i;
    }
    return null;
}

test "a watcher picks up a file the journal says was created" {
    const gpa = std.testing.allocator;
    var index = Index.init(gpa);
    defer index.deinit();

    const source: volume.Source = .{ .fake = .{ .files = 20 } };
    {
        const reader = try source.open(gpa);
        defer reader.close();
        _ = try ntfs.scanVolume(&index, reader, 'C');
    }
    try std.testing.expect(named(&index, "fresh.txt") == null);

    var monitor = Monitor.init(gpa, &index, source);
    defer monitor.deinit();
    try std.testing.expectEqual(@as(usize, 1), try monitor.start());

    var waited: u32 = 0;
    while (!monitor.hasPending() and waited < 5000) : (waited += 10) w.Sleep(10);
    monitor.stop();
    try std.testing.expectEqual(@as(usize, 1), try monitor.drain());
    const fresh = named(&index, "fresh.txt") orelse return error.NotFound;
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("C:\\dir0\\fresh.txt", index.path(fresh, &buf));
    try std.testing.expectEqual(fake.journal_start + 1, index.volumes.items[0].next_usn);
}
