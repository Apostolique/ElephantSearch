//! Fills in sizes and dates on a background thread, once the names are already
//! searchable.
//!
//! Reading `$MFT` costs gigabytes of disk on a big volume, which is far too
//! long to make anyone wait before their first search. Nothing in the search
//! path reads either field, so the pass can run behind the interface and let
//! the two columns appear as they arrive.

const std = @import("std");
const w = @import("win32.zig");
const idx = @import("index.zig");
const volume = @import("volume.zig");

/// Entries written between one lock and the next. Long enough that the locking
/// disappears into the disk read, short enough that a search waits on nothing.
const batch = 4096;

pub const Sizer = struct {
    gpa: std.mem.Allocator,
    index: *idx.Index,
    source: volume.Source,
    thread: ?std.Thread = null,

    filled: std.atomic.Value(u32) = .init(0),
    wanted: std.atomic.Value(u32) = .init(0),
    /// True until a pass is actually started, so a run that never needs one
    /// reads as done rather than as forever pending.
    finished: std.atomic.Value(bool) = .init(true),
    millis: std.atomic.Value(u64) = .init(0),
    /// Volumes the pass could not read at all. Filling nothing because a drive
    /// refused to open is a different answer from filling nothing because there
    /// was nothing there, and only one of them is a bug.
    failed: std.atomic.Value(u32) = .init(0),
    trouble: [32]u8 = undefined,
    trouble_len: std.atomic.Value(u8) = .init(0),
    /// Records the table claims to hold, and bytes of it actually read. A pass
    /// that fills nothing without erroring has to be able to say which of the
    /// two it got wrong.
    records: std.atomic.Value(u64) = .init(0),
    scanned: std.atomic.Value(u64) = .init(0),
    running: std.atomic.Value(bool) = .init(true),

    pub fn init(gpa: std.mem.Allocator, index: *idx.Index, source: volume.Source) Sizer {
        return .{ .gpa = gpa, .index = index, .source = source };
    }

    /// Starts the pass. A volume that will not open just goes unsized, which
    /// costs two columns and nothing else.
    pub fn start(self: *Sizer) void {
        if (self.index.volumes.items.len == 0) return;
        self.wanted.store(self.index.count(), .release);
        self.finished.store(false, .release);
        self.thread = std.Thread.spawn(.{}, work, .{self}) catch {
            self.finished.store(true, .release);
            self.wanted.store(0, .release);
            return;
        };
    }

    pub fn stop(self: *Sizer) void {
        self.running.store(false, .release);
        if (self.thread) |t| t.join();
        self.thread = null;
    }

    pub const Progress = struct {
        filled: u32,
        wanted: u32,
        finished: bool,
        millis: u64,
        failed: u32,
        /// Name of the first error, empty when nothing went wrong.
        trouble: []const u8,
        records: u64,
        scanned: u64,
    };

    pub fn progress(self: *const Sizer) Progress {
        return .{
            .filled = self.filled.load(.acquire),
            .wanted = self.wanted.load(.acquire),
            .finished = self.finished.load(.acquire),
            .millis = self.millis.load(.acquire),
            .failed = self.failed.load(.acquire),
            // The length is stored after the text, so seeing one means the
            // other is already there.
            .trouble = self.trouble[0..self.trouble_len.load(.acquire)],
            .records = self.records.load(.acquire),
            .scanned = self.scanned.load(.acquire),
        };
    }

    fn work(self: *Sizer) void {
        const timer = w.Timer.start();
        defer {
            self.millis.store(timer.readMillis(), .release);
            self.finished.store(true, .release);
        }
        const reader = self.source.open(self.gpa) catch |e| {
            _ = self.failed.fetchAdd(@intCast(self.index.volumes.items.len), .release);
            self.noteTrouble(e);
            return;
        };
        defer reader.close();

        for (self.index.volumes.items) |*vol| {
            if (!self.running.load(.acquire)) break;
            self.oneVolume(reader, vol) catch |e| switch (e) {
                error.Stopped => break,
                else => {
                    _ = self.failed.fetchAdd(1, .release);
                    self.noteTrouble(e);
                    // A service that broke off cannot be asked anything more on
                    // the same connection, so the rest go unsized too.
                    if (e == error.ServiceFailed) break;
                },
            };
        }
    }

    /// Keeps the first thing that went wrong, so a pass that quietly reads
    /// nothing can still say why. The text is written before the length, and
    /// the length is what a reader checks.
    fn noteTrouble(self: *Sizer, e: anyerror) void {
        if (self.trouble_len.load(.acquire) != 0) return;
        const name = @errorName(e);
        const n = @min(name.len, self.trouble.len);
        @memcpy(self.trouble[0..n], name[0..n]);
        self.trouble_len.store(@intCast(n), .release);
    }

    fn oneVolume(self: *Sizer, reader: volume.Reader, vol: *const idx.Volume) volume.Error!void {
        // A file reference carries a sequence number above the record number,
        // and records only know the latter, so the map gets flattened first.
        // The journal can be adding to the map, hence the lock.
        var highest: u64 = 0;
        {
            self.index.growing.acquire();
            defer self.index.growing.release();
            var it = vol.frn_map.keyIterator();
            while (it.next()) |frn| highest = @max(highest, frn.* & record_number_mask);
        }
        // Past this the map is mostly holes, and a record number that big is
        // more likely garbage than a real file.
        if (highest >= 1 << 32) return error.TableFailed;
        const by_record = try self.gpa.alloc(u32, @intCast(highest + 1));
        defer self.gpa.free(by_record);
        @memset(by_record, missing);
        {
            self.index.growing.acquire();
            defer self.index.growing.release();
            var it = vol.frn_map.iterator();
            while (it.next()) |kv| {
                const number = kv.key_ptr.* & record_number_mask;
                if (number > highest) continue;
                by_record[@intCast(number)] = kv.value_ptr.*;
            }
        }

        var take: Take = .{ .sizer = self, .by_record = by_record };
        defer if (take.held > 0) self.commit(take.pending[0..take.held]);
        try reader.sizes(vol.letter, highest + 1, .{ .ctx = &take, .table = Take.onTable, .batch = Take.onBatch });
    }

    /// Writes a batch in. The lock is against entries moving, which appending
    /// from the change journal can do at any moment.
    fn commit(self: *Sizer, found: []const Found) void {
        self.index.growing.acquire();
        defer self.index.growing.release();

        const slice = self.index.entries.slice();
        const sizes = slice.items(.size);
        const times = slice.items(.modified);
        const count = self.index.count();

        for (found) |f| {
            if (f.entry >= count) continue;
            sizes[f.entry] = f.size;
            times[f.entry] = f.modified;
        }
        _ = self.filled.fetchAdd(@intCast(found.len), .release);
    }
};

const Found = struct {
    entry: u32,
    size: u64,
    modified: i64,
};

/// Where the batches for one volume land on their way into the index.
const Take = struct {
    sizer: *Sizer,
    by_record: []const u32,
    pending: [batch]Found = undefined,
    held: usize = 0,

    fn onTable(ctx: *anyopaque, records: u64) volume.Error!void {
        const self: *Take = @ptrCast(@alignCast(ctx));
        _ = self.sizer.records.fetchAdd(records, .release);
    }

    fn onBatch(ctx: *anyopaque, bytes: []const u8, scanned: u64) volume.Error!void {
        const self: *Take = @ptrCast(@alignCast(ctx));
        const sizer = self.sizer;
        if (!sizer.running.load(.acquire)) return error.Stopped;
        var it = try volume.SizeIter.init(bytes);
        while (it.next()) |s| {
            if (s.number >= self.by_record.len) continue;
            const entry = self.by_record[@intCast(s.number)];
            if (entry == missing) continue;
            self.pending[self.held] = .{ .entry = entry, .size = s.size, .modified = s.modified };
            self.held += 1;
            if (self.held == self.pending.len) {
                sizer.commit(self.pending[0..self.held]);
                self.held = 0;
            }
        }
        _ = sizer.scanned.fetchAdd(scanned, .release);
    }
};

const missing: u32 = std.math.maxInt(u32);
/// A file reference is a 48 bit record number with a 16 bit sequence above it.
const record_number_mask: u64 = 0x0000_FFFF_FFFF_FFFF;

test "sizes from a made up volume land on the entries they belong to" {
    const fake = @import("fake.zig");
    const ntfs = @import("ntfs.zig");
    const gpa = std.testing.allocator;
    var index = idx.Index.init(gpa);
    defer index.deinit();

    const source: volume.Source = .{ .fake = .{ .files = 5000 } };
    {
        const reader = try source.open(gpa);
        defer reader.close();
        _ = try ntfs.scanVolume(&index, reader, 'C');
    }

    var sizer = Sizer.init(gpa, &index, source);
    sizer.start();
    while (!sizer.progress().finished) w.Sleep(5);
    sizer.stop();

    const pass = sizer.progress();
    try std.testing.expectEqual(@as(u32, 0), pass.failed);
    try std.testing.expectEqual(@as(u32, 5000 + fake.directories), pass.filled);

    const frn = fake.frnOf(16 + fake.directories + 1234);
    const entry = index.volumes.items[0].frn_map.get(frn).?;
    try std.testing.expectEqual(fake.sizeOf(frn), index.entries.items(.size)[entry]);
    try std.testing.expect(index.entries.items(.modified)[entry] > 0);
}
