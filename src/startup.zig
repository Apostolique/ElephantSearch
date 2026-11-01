//! Bringing an index up: the cache, the drives, and the layout pass that has to
//! follow either of them.
//!
//! Both front ends need this and getting it subtly different would be a real
//! bug, because wrongly deciding a stale cache is still good enough shows up as
//! a search that quietly misses files rather than as a crash. The console
//! prints as it goes and the window puts the same facts in its status line, so
//! progress leaves through a `Watcher` instead of being written here.

const std = @import("std");
const w = @import("win32.zig");
const cache = @import("cache.zig");
const idx = @import("index.zig");
const mft = @import("mft.zig");
const ntfs = @import("ntfs.zig");
const synth = @import("synth.zig");
const volume = @import("volume.zig");

pub const Options = struct {
    /// Drive letters to read, or empty for every fixed NTFS volume.
    drives: []const u8 = &.{},
    rebuild: bool = false,
    synthetic: u32 = 0,
    order: synth.Order = .scattered,
    fanout: u32 = 8,
    /// Where the volumes are read from.
    source: volume.Source = .direct,
    /// Cleared for a run that must neither load nor replace the saved index,
    /// such as one reading a made up volume through a test pipe.
    use_cache: bool = true,
};

/// What the index cost and whether it can be saved, handed back once every
/// drive has been read.
pub const Ready = struct {
    /// Where the index belongs on disk, or null when this run deliberately did
    /// not index the whole machine. The caller owns it.
    cache_path: ?[:0]u16 = null,
    /// Cleared by any drive that would not open. A partial index must not be
    /// saved, because a later run has no way to tell it apart from a full one.
    whole: bool = true,
    /// Set when the entries came back from the cache instead of the drives,
    /// which also means the sizes and dates came with them.
    restored: bool = false,
    /// Set when the cache was taken as it was saved because the drives would
    /// not open to catch it up. Nothing updates a frozen index, and it is
    /// never written back, since it holds nothing the file does not.
    frozen: bool = false,
    /// When the cache file was last written, as a file time, or 0 when the
    /// index did not come from it.
    saved: i64 = 0,
    entries: u32 = 0,
    millis: u64 = 0,
    /// Roughly what the entries occupy, for the report.
    bytes: usize = 0,
    volumes: usize = 0,
};

/// Why one drive did not join the index. The rest of `ntfs.Error` means a bug
/// or a failed allocation, which stops the whole run rather than one volume.
pub const Trouble = error{ AccessDenied, OpenFailed, EnumFailed, ServiceFailed };

pub const Event = union(enum) {
    synthetic: struct { entries: u32, millis: u64, order: synth.Order },
    restored: struct { entries: u32, millis: u64 },
    /// The cache, taken as it was saved because the drives refused to open.
    frozen: struct { entries: u32, millis: u64, saved: i64 },
    /// Sent before a drive is read, so a front end can say which one is taking
    /// the ten seconds.
    reading: struct { letter: u8 },
    scanned: struct { letter: u8, entries: u32, millis: u64 },
    failed: struct { letter: u8, reason: Trouble },
    ready: Ready,
};

/// Where progress goes. Called on whatever thread `bringUp` runs on, which for
/// the window is not the one painting it.
pub const Watcher = struct {
    ctx: *anyopaque,
    on: *const fn (ctx: *anyopaque, ev: Event) void,
};

fn note(watcher: ?Watcher, ev: Event) void {
    if (watcher) |v| v.on(v.ctx, ev);
}

pub const Error = error{
    /// No fixed NTFS volume to read, so there is nothing this program can do.
    NoVolume,
    /// Every drive that was tried failed, usually for want of elevation.
    NothingIndexed,
};

/// Fills `index` and returns what it cost. Leaves it laid out depth first and
/// ready to search, but does not start the journal watcher or the size pass:
/// those outlive this call and belong to the front end.
pub fn bringUp(
    gpa: std.mem.Allocator,
    index: *idx.Index,
    opts: Options,
    watcher: ?Watcher,
) !Ready {
    var out: Ready = .{};
    var indexed: usize = 0;

    if (opts.synthetic > 0) {
        const timer = w.Timer.start();
        try synth.build(index, .{
            .entries = opts.synthetic,
            .order = opts.order,
            .fanout = opts.fanout,
        });
        out.millis = timer.readMillis();
        indexed = 1;
        note(watcher, .{ .synthetic = .{
            .entries = index.count(),
            .millis = out.millis,
            .order = opts.order,
        } });
    }

    // The drive barely changes between two runs a minute apart, and the journal
    // says exactly what did, so a saved index only has to be walked forward.
    // Asking for particular drives means the index deliberately is not the
    // whole machine, so it neither comes from the cache nor replaces it.
    const partial = opts.synthetic > 0 or opts.drives.len > 0 or !opts.use_cache;
    out.cache_path = if (partial) null else cache.defaultPath(gpa);
    errdefer if (out.cache_path) |p| gpa.free(p);

    // Times the whole attempt, which is mostly reading the file. Starting it
    // after the load would report how long the checks took and call that the
    // cost of the cache.
    const cache_timer = w.Timer.start();

    // One reader for the whole bring up. A service that will not answer leaves
    // it null, which plays out like a drive that refused: the cache is taken
    // as it was saved, or every drive says why it was skipped.
    var reader: ?volume.Reader = if (opts.synthetic > 0) null else opts.source.open(gpa) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
    defer if (reader) |r| r.close();

    // A rebuild leaves the old file where it is. A finished scan replaces it on
    // the way out, while one the drives refused would otherwise have thrown
    // away the only index there was.
    if (out.cache_path) |p| if (!opts.rebuild) {
        if (cache.load(index, p)) |saved| switch (if (reader) |r| ntfs.resumable(index, r) else .denied) {
            .ready => {
                out.restored = true;
                out.saved = saved;
            },
            .denied => {
                out.restored = true;
                out.frozen = true;
                out.whole = false;
                out.saved = saved;
            },
            // Loaded but too far behind for the journal to bridge.
            .behind => cache.forget(index),
        } else |_| {}
    };

    if (out.restored) {
        indexed = index.volumes.items.len;

        // Files added after a layout sit outside every subtree run, so a scoped
        // search walks their parents one at a time. That tail grows a little
        // with every session, and past a point laying the whole thing out again
        // costs less than carrying it.
        if (index.count() - index.ordered > index.count() / 16) {
            try index.orderDepthFirst();
        }
        out.millis = cache_timer.readMillis();
        note(watcher, if (out.frozen)
            .{ .frozen = .{ .entries = index.count(), .millis = out.millis, .saved = out.saved } }
        else
            .{ .restored = .{ .entries = index.count(), .millis = out.millis } });
    }

    var letter_buf: [26]u8 = undefined;
    const drives = if (out.restored or opts.synthetic > 0)
        letter_buf[0..0]
    else if (opts.drives.len > 0)
        opts.drives
    else
        ntfs.ntfsDrives(&letter_buf);
    if (drives.len == 0 and opts.synthetic == 0 and !out.restored) return Error.NoVolume;

    for (drives) |letter| {
        note(watcher, .{ .reading = .{ .letter = letter } });
        const r = reader orelse {
            out.whole = false;
            note(watcher, .{ .failed = .{ .letter = letter, .reason = error.ServiceFailed } });
            continue;
        };
        const stats = ntfs.scanVolume(index, r, letter) catch |e| {
            const reason: Trouble = switch (e) {
                error.AccessDenied => error.AccessDenied,
                error.OpenFailed => error.OpenFailed,
                error.EnumFailed => error.EnumFailed,
                error.ServiceFailed => error.ServiceFailed,
                error.OutOfMemory => return error.OutOfMemory,
                // Nothing a listing does can lose a journal, read the table
                // or be stopped, so these would be a bug.
                error.JournalLost, error.TableFailed, error.Stopped => error.EnumFailed,
            };
            // A service that broke off part way has no next request in it.
            if (e == error.ServiceFailed) {
                r.close();
                reader = opts.source.open(gpa) catch null;
            }
            out.whole = false;
            note(watcher, .{ .failed = .{ .letter = letter, .reason = reason } });
            continue;
        };
        out.millis += stats.millis;
        indexed += 1;
        note(watcher, .{ .scanned = .{
            .letter = letter,
            .entries = stats.entries,
            .millis = stats.millis,
        } });
    }
    if (indexed == 0) return Error.NothingIndexed;

    // A restored index is already laid out, and reordering it would only
    // invalidate the file reference map it came with.
    if (!out.restored) {
        const timer = w.Timer.start();
        try index.orderDepthFirst();
        out.millis += timer.readMillis();
    }

    // Entries are held as one array per field, so they cost the sum of the
    // field sizes. @sizeOf would count padding between them that is never
    // actually allocated.
    out.entries = index.count();
    out.bytes = @TypeOf(index.entries).capacityInBytes(index.entries.len) + index.names.items.len;
    out.volumes = indexed;
    note(watcher, .{ .ready = out });
    return out;
}

/// Writes the index back out, or throws the old file away rather than leaving
/// one that no longer describes the drive. Only ever called once the watchers
/// have stopped and everything they queued has been applied, so the journal
/// position saved really is the point the entries were caught up to.
pub fn saveCache(index: *const idx.Index, ready: Ready, gpa: std.mem.Allocator) void {
    const path = ready.cache_path orelse return;
    if (!ready.whole) return;
    cache.save(index, path, gpa) catch cache.discard(path);
}

/// The day a file time falls on in the machine's own zone, as `2026-09-13`, or
/// an empty string when there is no time to show.
pub fn day(buf: *[16]u8, ft: i64) []const u8 {
    var local: i64 = 0;
    const shifted = if (w.FileTimeToLocalFileTime(&ft, &local) != 0) local else ft;
    const d = mft.breakDown(shifted) orelse return "";
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ d.year, d.month, d.day }) catch "";
}
