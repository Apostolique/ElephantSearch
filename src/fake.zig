//! A made up volume behind the same reader as a real one, so the whole path
//! from a volume to the index can run without administrator rights: in the
//! tests, and in the service started by hand with `--fake`.
//!
//! Every letter holds ten directories and `files` files spread across them.
//! The journal holds one change, a file called `fresh.txt` showing up in the
//! first directory, so a watcher has something to pick up.

const std = @import("std");
const w = @import("win32.zig");
const volume = @import("volume.zig");

pub const Options = struct {
    files: u32 = 1000,
    /// A letter that refuses everything for want of rights, or 0 for none.
    denied: u8 = 0,
};

pub const journal_id: u64 = 0xE1E;
/// Where the journal stands before the one change.
pub const journal_start: i64 = 1000;
pub const directories = 10;
/// Records below this are the volume's own metadata files.
const first_record = 16;
/// NTFS puts a sequence number above the record number in a file reference.
const sequence: u64 = 1 << 48;
/// A Tuesday in 2022, in file time.
const base_time: i64 = 133_000_000_000_000_000;

pub fn frnOf(number: u64) u64 {
    return number | sequence;
}

pub const Fake = struct {
    gpa: std.mem.Allocator,
    opts: Options,

    const vtable: volume.Reader.VTable = .{
        .journal = journal,
        .enumerate = enumerate,
        .changes = changes,
        .sizes = sizes,
        .close = close,
    };

    pub fn open(gpa: std.mem.Allocator, opts: Options) volume.Error!volume.Reader {
        const self = try gpa.create(Fake);
        self.* = .{ .gpa = gpa, .opts = opts };
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn close(ptr: *anyopaque) void {
        const self: *Fake = @ptrCast(@alignCast(ptr));
        self.gpa.destroy(self);
    }

    fn check(self: *const Fake, letter: u8) volume.Error!void {
        if (letter < 'A' or letter > 'Z') return error.OpenFailed;
        if (letter == self.opts.denied) return error.AccessDenied;
    }

    fn records(self: *const Fake) u64 {
        return first_record + directories + self.opts.files + 1;
    }

    fn journal(ptr: *anyopaque, letter: u8) volume.Error!?volume.Journal {
        const self: *Fake = @ptrCast(@alignCast(ptr));
        try self.check(letter);
        return .{ .id = journal_id, .first = 0, .next = journal_start, .lowest_valid = 0 };
    }

    fn enumerate(ptr: *anyopaque, letter: u8, sink: volume.NameSink) volume.Error!void {
        const self: *Fake = @ptrCast(@alignCast(ptr));
        try self.check(letter);

        var out = try volume.Batcher.init(self.gpa);
        defer out.deinit(self.gpa);
        var name_buf: [32]u8 = undefined;

        for (0..directories) |d| {
            const name = std.fmt.bufPrint(&name_buf, "dir{d}", .{d}) catch unreachable;
            try out.addName(sink, .{
                .frn = frnOf(first_record + d),
                // The root itself is never listed, the same as on a real drive.
                .parent_frn = frnOf(5),
                .is_dir = true,
                .name = name,
            });
        }
        for (0..self.opts.files) |f| {
            const name = std.fmt.bufPrint(&name_buf, "file{d}.txt", .{f}) catch unreachable;
            try out.addName(sink, .{
                .frn = frnOf(first_record + directories + f),
                .parent_frn = frnOf(first_record + f % directories),
                .is_dir = false,
                .name = name,
            });
        }
        try out.flushNames(sink);
    }

    fn changes(ptr: *anyopaque, letter: u8, id: u64, from: i64, sink: volume.NameSink) volume.Error!i64 {
        const self: *Fake = @ptrCast(@alignCast(ptr));
        try self.check(letter);
        if (id != journal_id or from < journal_start) return error.JournalLost;
        if (from > journal_start) return from;

        var out = try volume.Batcher.init(self.gpa);
        defer out.deinit(self.gpa);
        try out.addName(sink, .{
            .frn = frnOf(self.records() - 1),
            .parent_frn = frnOf(first_record),
            .reason = w.USN_REASON_FILE_CREATE | w.USN_REASON_CLOSE,
            .is_dir = false,
            .name = "fresh.txt",
        });
        try out.flushNames(sink);
        return journal_start + 1;
    }

    fn sizes(ptr: *anyopaque, letter: u8, limit: u64, sink: volume.SizeSink) volume.Error!void {
        const self: *Fake = @ptrCast(@alignCast(ptr));
        try self.check(letter);

        const total = self.records();
        try sink.table(sink.ctx, total);

        var out: [512 * volume.size_bytes]u8 = undefined;
        var held: usize = 0;
        var number: u64 = first_record;
        const end = @min(limit, total);
        while (number < end) : (number += 1) {
            const is_dir = number < first_record + directories;
            held += volume.encodeSize(out[held..], .{
                .number = number,
                .size = if (is_dir) 0 else number * 10,
                .modified = base_time + @as(i64, @intCast(number)),
            });
            if (held == out.len) {
                try sink.batch(sink.ctx, out[0..held], (held / volume.size_bytes) * 1024);
                held = 0;
            }
        }
        try sink.batch(sink.ctx, out[0..held], (held / volume.size_bytes) * 1024);
    }
};

/// The size the made up record behind `frn` reports.
pub fn sizeOf(frn: u64) u64 {
    return (frn & (sequence - 1)) * 10;
}
