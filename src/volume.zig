//! The four things this program needs a raw volume for, and nothing else:
//! where the change journal stands, every name on the volume, the journal
//! records after a given point, and the size and date in every file record.
//! Opening a volume needs administrator rights, which is why these four are
//! also exactly what the service does for a client.
//!
//! Whoever does the reading, the answers come back the same way: parsed fields
//! packed into batches, never the records themselves. A file record holds the
//! contents of a small file next to its name, so passing records along would
//! hand a client the bytes of files it has no right to open.

const std = @import("std");
const w = @import("win32.zig");
const mft = @import("mft.zig");
const pipe = @import("pipe.zig");
const fake = @import("fake.zig");

pub const Error = error{
    /// The volume would not open for want of administrator rights.
    AccessDenied,
    /// Not a drive letter with an NTFS volume behind it, or it would not open.
    OpenFailed,
    /// The volume opened but would not list its names or its journal.
    EnumFailed,
    /// The journal wrapped past the point asked for, or was turned off. Only a
    /// rescan can put an index back in sync.
    JournalLost,
    /// The master file table would not open or stopped reading part way.
    TableFailed,
    /// The service stopped answering, or answered something that makes no
    /// sense. Starting over with a new connection is the only way on.
    ServiceFailed,
    /// Whoever was taking the answers asked for no more of them.
    Stopped,
    OutOfMemory,
};

pub const Journal = struct {
    id: u64,
    first: i64,
    next: i64,
    lowest_valid: i64,

    /// The oldest position a reader can still start from.
    pub fn oldest(self: Journal) i64 {
        return @max(self.first, self.lowest_valid);
    }
};

/// One entry off the name listing or the journal. The listing leaves `reason`
/// at zero.
pub const Name = struct {
    frn: u64,
    parent_frn: u64,
    reason: u32 = 0,
    is_dir: bool,
    name: []const u8,
};

/// The size and date out of one file record, keyed by its record number.
pub const Size = struct {
    number: u64,
    size: u64,
    modified: i64,
};

/// Bytes a name takes in a batch ahead of its text.
pub const name_header = 24;
/// Bytes one size takes in a batch.
pub const size_bytes = 24;
/// The longest name NTFS allows, 255 UTF-16 units, as UTF-8.
pub const max_name = 3 * 255;
/// How big a batch gets before it is handed over. Also bounds what the service
/// puts in one message.
pub const batch_bytes = 256 * 1024;

pub fn encodeName(out: []u8, n: Name) usize {
    std.debug.assert(n.name.len <= max_name);
    const total = name_header + n.name.len;
    std.debug.assert(out.len >= total);
    std.mem.writeInt(u64, out[0..8], n.frn, .little);
    std.mem.writeInt(u64, out[8..16], n.parent_frn, .little);
    std.mem.writeInt(u32, out[16..20], n.reason, .little);
    std.mem.writeInt(u16, out[20..22], @intCast(n.name.len), .little);
    out[22] = @intFromBool(n.is_dir);
    out[23] = 0;
    @memcpy(out[name_header..total], n.name);
    return total;
}

/// Walks a batch of names. A batch that runs out part way through an entry, or
/// claims a name longer than NTFS allows, did not come from this program.
pub const NameIter = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn next(self: *NameIter) Error!?Name {
        const rest = self.bytes[self.pos..];
        if (rest.len == 0) return null;
        if (rest.len < name_header) return error.ServiceFailed;
        const len = std.mem.readInt(u16, rest[20..22], .little);
        if (len == 0 or len > max_name or rest.len - name_header < len) return error.ServiceFailed;
        self.pos += name_header + len;
        return .{
            .frn = std.mem.readInt(u64, rest[0..8], .little),
            .parent_frn = std.mem.readInt(u64, rest[8..16], .little),
            .reason = std.mem.readInt(u32, rest[16..20], .little),
            .is_dir = rest[22] != 0,
            .name = rest[name_header..][0..len],
        };
    }
};

pub fn encodeSize(out: []u8, s: Size) usize {
    std.debug.assert(out.len >= size_bytes);
    std.mem.writeInt(u64, out[0..8], s.number, .little);
    std.mem.writeInt(u64, out[8..16], s.size, .little);
    std.mem.writeInt(i64, out[16..24], s.modified, .little);
    return size_bytes;
}

pub const SizeIter = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn init(bytes: []const u8) Error!SizeIter {
        if (bytes.len % size_bytes != 0) return error.ServiceFailed;
        return .{ .bytes = bytes };
    }

    pub fn next(self: *SizeIter) ?Size {
        if (self.pos == self.bytes.len) return null;
        const at = self.bytes[self.pos..][0..size_bytes];
        self.pos += size_bytes;
        return .{
            .number = std.mem.readInt(u64, at[0..8], .little),
            .size = std.mem.readInt(u64, at[8..16], .little),
            .modified = std.mem.readInt(i64, at[16..24], .little),
        };
    }
};

/// Fills a batch and hands it over whenever the next entry would not fit.
pub const Batcher = struct {
    buf: []u8,
    len: usize = 0,

    pub fn init(gpa: std.mem.Allocator) Error!Batcher {
        return .{ .buf = try gpa.alloc(u8, batch_bytes) };
    }

    pub fn deinit(self: *Batcher, gpa: std.mem.Allocator) void {
        gpa.free(self.buf);
    }

    pub fn addName(self: *Batcher, sink: NameSink, n: Name) Error!void {
        if (self.len + name_header + n.name.len > self.buf.len) try self.flushNames(sink);
        self.len += encodeName(self.buf[self.len..], n);
    }

    pub fn flushNames(self: *Batcher, sink: NameSink) Error!void {
        if (self.len == 0) return;
        defer self.len = 0;
        try sink.batch(sink.ctx, self.buf[0..self.len]);
    }
};

pub const NameSink = struct {
    ctx: *anyopaque,
    batch: *const fn (ctx: *anyopaque, bytes: []const u8) Error!void,
};

pub const SizeSink = struct {
    ctx: *anyopaque,
    /// How many records the table holds, said once before any batch.
    table: *const fn (ctx: *anyopaque, records: u64) Error!void,
    /// `scanned` is how many bytes of the table were read to find these.
    batch: *const fn (ctx: *anyopaque, bytes: []const u8, scanned: u64) Error!void,
};

/// Somewhere the four answers can come from: the volumes themselves, the
/// service, or a made up volume for tests. One per thread, since none of them
/// can be shared.
pub const Reader = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        journal: *const fn (ptr: *anyopaque, letter: u8) Error!?Journal,
        enumerate: *const fn (ptr: *anyopaque, letter: u8, sink: NameSink) Error!void,
        changes: *const fn (ptr: *anyopaque, letter: u8, journal_id: u64, from: i64, sink: NameSink) Error!i64,
        sizes: *const fn (ptr: *anyopaque, letter: u8, limit: u64, sink: SizeSink) Error!void,
        close: *const fn (ptr: *anyopaque) void,
    };

    /// Where the journal on `letter` stands, or null when it has none.
    pub fn journal(self: Reader, letter: u8) Error!?Journal {
        return self.vtable.journal(self.ptr, letter);
    }

    /// Every name on `letter`, in batches.
    pub fn enumerate(self: Reader, letter: u8, sink: NameSink) Error!void {
        return self.vtable.enumerate(self.ptr, letter, sink);
    }

    /// One read of the journal from `from`, in batches. Returns where the next
    /// read starts, which is `from` again when nothing has happened since.
    pub fn changes(self: Reader, letter: u8, journal_id: u64, from: i64, sink: NameSink) Error!i64 {
        return self.vtable.changes(self.ptr, letter, journal_id, from, sink);
    }

    /// The size and date of every file record below `limit`, in batches.
    pub fn sizes(self: Reader, letter: u8, limit: u64, sink: SizeSink) Error!void {
        return self.vtable.sizes(self.ptr, letter, limit, sink);
    }

    pub fn close(self: Reader) void {
        self.vtable.close(self.ptr);
    }
};

/// Which kind of reader a front end hands out to its threads.
pub const Source = union(enum) {
    direct,
    service: pipe.Address,
    fake: fake.Options,

    pub fn open(self: Source, gpa: std.mem.Allocator) Error!Reader {
        return switch (self) {
            .direct => Direct.open(gpa),
            .service => |at| pipe.Remote.open(gpa, at) catch |e| switch (e) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.ServiceFailed,
            },
            .fake => |opts| fake.Fake.open(gpa, opts),
        };
    }
};

/// Drive letters of every NTFS volume on the machine.
pub fn ntfsDrives(buf: *[26]u8) []u8 {
    var n: usize = 0;
    const mask = w.GetLogicalDrives();
    for (0..26) |i| {
        if (mask & (@as(u32, 1) << @intCast(i)) == 0) continue;
        const letter: u8 = @intCast('A' + i);
        if (!isNtfs(letter)) continue;
        buf[n] = letter;
        n += 1;
    }
    return buf[0..n];
}

pub fn isNtfs(letter: u8) bool {
    if (letter < 'A' or letter > 'Z') return false;
    const root = [_:0]u16{ letter, ':', '\\' };
    var fs_name: [16]u16 = undefined;
    if (w.GetVolumeInformationW(&root, null, 0, null, null, null, &fs_name, fs_name.len) == 0) return false;
    const ntfs = [_]u16{ 'N', 'T', 'F', 'S', 0 };
    return std.mem.eql(u16, fs_name[0..5], &ntfs);
}

/// Opens the raw volume. Needs administrator rights.
pub fn openVolume(letter: u8) Error!w.HANDLE {
    const p = [_:0]u16{ '\\', '\\', '.', '\\', letter, ':' };
    const h = w.CreateFileW(
        &p,
        w.GENERIC_READ,
        w.FILE_SHARE_READ | w.FILE_SHARE_WRITE | w.FILE_SHARE_DELETE,
        null,
        w.OPEN_EXISTING,
        w.FILE_FLAG_BACKUP_SEMANTICS,
        null,
    );
    if (h == w.INVALID_HANDLE_VALUE) {
        return switch (w.GetLastError()) {
            w.ERROR_ACCESS_DENIED => error.AccessDenied,
            else => error.OpenFailed,
        };
    }
    return h;
}

/// Reads the volumes in this process. What an elevated run uses, and what the
/// service runs on behalf of everybody else.
pub const Direct = struct {
    gpa: std.mem.Allocator,
    /// Kept open for the life of the reader, so a journal polled five times a
    /// second does not open its volume five times a second.
    handles: [26]?w.HANDLE = @splat(null),

    const vtable: Reader.VTable = .{
        .journal = journal,
        .enumerate = enumerate,
        .changes = changes,
        .sizes = sizes,
        .close = close,
    };

    pub fn open(gpa: std.mem.Allocator) Error!Reader {
        const self = try gpa.create(Direct);
        self.* = .{ .gpa = gpa };
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn close(ptr: *anyopaque) void {
        const self: *Direct = @ptrCast(@alignCast(ptr));
        for (self.handles) |h| if (h) |open_handle| {
            _ = w.CloseHandle(open_handle);
        };
        self.gpa.destroy(self);
    }

    /// Anything but a letter with an NTFS volume behind it is refused before
    /// it gets near `CreateFileW`, since the service runs this for whoever
    /// asks and `\\.\` reaches a lot more than volumes.
    fn handle(self: *Direct, letter: u8) Error!w.HANDLE {
        if (letter < 'A' or letter > 'Z') return error.OpenFailed;
        const slot = &self.handles[letter - 'A'];
        if (slot.*) |h| return h;
        if (!isNtfs(letter)) return error.OpenFailed;
        const h = try openVolume(letter);
        slot.* = h;
        return h;
    }

    fn journal(ptr: *anyopaque, letter: u8) Error!?Journal {
        const self: *Direct = @ptrCast(@alignCast(ptr));
        const h = try self.handle(letter);
        var data: w.UsnJournalData = undefined;
        var returned: w.DWORD = 0;
        const ok = w.DeviceIoControl(h, w.FSCTL_QUERY_USN_JOURNAL, null, 0, &data, @sizeOf(w.UsnJournalData), &returned, null);
        if (ok == 0) return null;
        return .{
            .id = data.UsnJournalID,
            .first = data.FirstUsn,
            .next = data.NextUsn,
            .lowest_valid = data.LowestValidUsn,
        };
    }

    fn enumerate(ptr: *anyopaque, letter: u8, sink: NameSink) Error!void {
        const self: *Direct = @ptrCast(@alignCast(ptr));
        const h = try self.handle(letter);

        // Records come back packed 8-byte aligned, so back the buffer with u64.
        const words = try self.gpa.alloc(u64, 1 << 17); // 1 MiB
        defer self.gpa.free(words);
        const buf = std.mem.sliceAsBytes(words);

        var out = try Batcher.init(self.gpa);
        defer out.deinit(self.gpa);

        var med: w.MftEnumData = .{
            .StartFileReferenceNumber = 0,
            .LowUsn = 0,
            .HighUsn = std.math.maxInt(i64),
        };
        var name_utf8: [max_name]u8 = undefined;

        while (true) {
            var returned: w.DWORD = 0;
            const ok = w.DeviceIoControl(
                h,
                w.FSCTL_ENUM_USN_DATA,
                &med,
                @sizeOf(w.MftEnumData),
                buf.ptr,
                @intCast(buf.len),
                &returned,
                null,
            );
            if (ok == 0) {
                if (w.GetLastError() == w.ERROR_HANDLE_EOF) break;
                return error.EnumFailed;
            }
            if (returned <= @sizeOf(u64)) break;

            med.StartFileReferenceNumber = std.mem.readInt(u64, buf[0..8], .little);
            try parseRecords(buf[0..returned], &name_utf8, &out, sink, false);
        }
        try out.flushNames(sink);
    }

    fn changes(ptr: *anyopaque, letter: u8, journal_id: u64, from: i64, sink: NameSink) Error!i64 {
        const self: *Direct = @ptrCast(@alignCast(ptr));
        const h = try self.handle(letter);

        const words = try self.gpa.alloc(u64, 1 << 13); // 64 KiB
        defer self.gpa.free(words);
        const buf = std.mem.sliceAsBytes(words);

        var req: w.ReadUsnJournalData = .{
            .StartUsn = from,
            .ReasonMask = 0xFFFF_FFFF,
            .ReturnOnlyOnClose = 0,
            .Timeout = 0,
            .BytesToWaitFor = 0,
            .UsnJournalID = journal_id,
        };
        var returned: w.DWORD = 0;
        const ok = w.DeviceIoControl(
            h,
            w.FSCTL_READ_USN_JOURNAL,
            &req,
            @sizeOf(w.ReadUsnJournalData),
            buf.ptr,
            @intCast(buf.len),
            &returned,
            null,
        );
        if (ok == 0) {
            return switch (w.GetLastError()) {
                w.ERROR_JOURNAL_ENTRY_DELETED, w.ERROR_JOURNAL_NOT_ACTIVE => error.JournalLost,
                else => error.EnumFailed,
            };
        }
        if (returned <= @sizeOf(u64)) return from;

        var out = try Batcher.init(self.gpa);
        defer out.deinit(self.gpa);
        var name_utf8: [max_name]u8 = undefined;
        try parseRecords(buf[0..returned], &name_utf8, &out, sink, true);
        try out.flushNames(sink);
        return std.mem.readInt(i64, buf[0..8], .little);
    }

    fn sizes(ptr: *anyopaque, letter: u8, limit: u64, sink: SizeSink) Error!void {
        const self: *Direct = @ptrCast(@alignCast(ptr));
        const h = try self.handle(letter);

        var table = mft.Volume.open(self.gpa, h) catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.TableFailed,
        };
        defer table.deinit();

        const record_size = table.geo.bytes_per_record;
        const total = table.records();
        try sink.table(sink.ctx, total);
        if (total == 0) return;

        // The table stays as big as it ever was, so a volume that once held
        // millions of files keeps a mostly empty tail. Nothing past the last
        // record anybody wants is worth the disk it would cost to read.
        const wanted = @min(limit, total);
        const end = @min(table.bytes, wanted * record_size);

        const chunk = @max(@as(usize, table.geo.bytes_per_cluster) * 256, record_size);
        const buf = try self.gpa.alloc(u8, chunk);
        defer self.gpa.free(buf);

        const out = try self.gpa.alloc(u8, 4096 * size_bytes);
        defer self.gpa.free(out);
        var held: usize = 0;
        var scanned: u64 = 0;

        var cursor: mft.Cursor = .{};
        var at: u64 = 0;
        var trouble = false;
        while (at < end) {
            const got = table.read(at, buf, &cursor) catch {
                trouble = true;
                break;
            };
            if (got < record_size) break;

            var off: usize = 0;
            while (off + record_size <= got) : (off += record_size) {
                const number = (at + off) / record_size;
                if (number >= wanted) break;
                const record = buf[off..][0..record_size];

                // A record that will not parse is one file without a size, not
                // a reason to give up on the rest of the table.
                mft.applyFixups(record, table.geo.bytes_per_sector) catch continue;
                const info = mft.readInfo(record, number) catch continue;
                if (!info.in_use or info.extends != 0) continue;

                held += encodeSize(out[held..], .{ .number = number, .size = info.size, .modified = info.modified });
                if (held == out.len) {
                    try sink.batch(sink.ctx, out[0..held], scanned);
                    scanned = 0;
                    held = 0;
                }
            }
            at += off;
            scanned += off;
            if (off == 0) break;
        }
        try sink.batch(sink.ctx, out[0..held], scanned);
        if (trouble) return error.TableFailed;
    }
};

/// Turns what `FSCTL_ENUM_USN_DATA` or `FSCTL_READ_USN_JOURNAL` handed back
/// into names. Both lead with eight bytes the caller has already read.
fn parseRecords(
    buf: []const u8,
    name_utf8: *[max_name]u8,
    out: *Batcher,
    sink: NameSink,
    keep_reason: bool,
) Error!void {
    var pos: usize = @sizeOf(u64);
    while (pos + 60 <= buf.len) {
        const rec: *align(1) const w.UsnRecordV2 = @ptrCast(&buf[pos]);
        const rec_len = rec.RecordLength;
        if (rec_len < 60 or pos + rec_len > buf.len) break;
        defer pos += rec_len;

        if (rec.MajorVersion != 2) continue;
        const name16 = rec.fileName();
        if (name16.len > 255) continue;
        const aligned: []const u16 = @alignCast(name16);
        const n = std.unicode.wtf16LeToWtf8(name_utf8, aligned);
        if (n == 0) continue;

        try out.addName(sink, .{
            .frn = rec.FileReferenceNumber,
            .parent_frn = rec.ParentFileReferenceNumber,
            .reason = if (keep_reason) rec.Reason else 0,
            .is_dir = rec.isDir(),
            .name = name_utf8[0..n],
        });
    }
}

const testing = std.testing;

test "names survive a batch and come back in order" {
    var buf: [256]u8 = undefined;
    var len: usize = 0;
    len += encodeName(buf[len..], .{ .frn = 7, .parent_frn = 5, .is_dir = true, .name = "src" });
    len += encodeName(buf[len..], .{ .frn = 9, .parent_frn = 7, .reason = 0x100, .is_dir = false, .name = "main.zig" });

    var it: NameIter = .{ .bytes = buf[0..len] };
    const a = (try it.next()).?;
    try testing.expectEqual(@as(u64, 7), a.frn);
    try testing.expect(a.is_dir);
    try testing.expectEqualStrings("src", a.name);
    const b = (try it.next()).?;
    try testing.expectEqual(@as(u64, 7), b.parent_frn);
    try testing.expectEqual(@as(u32, 0x100), b.reason);
    try testing.expectEqualStrings("main.zig", b.name);
    try testing.expectEqual(@as(?Name, null), try it.next());
}

test "a batch cut off part way through a name is refused" {
    var buf: [64]u8 = undefined;
    const len = encodeName(&buf, .{ .frn = 1, .parent_frn = 5, .is_dir = false, .name = "readme.md" });
    var it: NameIter = .{ .bytes = buf[0 .. len - 1] };
    try testing.expectError(error.ServiceFailed, it.next());

    var short: NameIter = .{ .bytes = buf[0..10] };
    try testing.expectError(error.ServiceFailed, short.next());
}

test "a name claiming more than NTFS allows is refused" {
    var buf: [64]u8 = undefined;
    _ = encodeName(&buf, .{ .frn = 1, .parent_frn = 5, .is_dir = false, .name = "a" });
    std.mem.writeInt(u16, buf[20..22], max_name + 1, .little);
    var it: NameIter = .{ .bytes = &buf };
    try testing.expectError(error.ServiceFailed, it.next());
}

test "sizes survive a batch" {
    var buf: [2 * size_bytes]u8 = undefined;
    _ = encodeSize(buf[0..], .{ .number = 40, .size = 1234, .modified = -1 });
    _ = encodeSize(buf[size_bytes..], .{ .number = 41, .size = 0, .modified = 99 });
    var it = try SizeIter.init(&buf);
    const a = it.next().?;
    try testing.expectEqual(@as(u64, 40), a.number);
    try testing.expectEqual(@as(u64, 1234), a.size);
    try testing.expectEqual(@as(i64, -1), a.modified);
    try testing.expectEqual(@as(u64, 41), it.next().?.number);
    try testing.expectEqual(@as(?Size, null), it.next());

    try testing.expectError(error.ServiceFailed, SizeIter.init(buf[0 .. size_bytes + 1]));
}

test "the direct reader refuses anything that is not a drive letter" {
    const reader = try Direct.open(testing.allocator);
    defer reader.close();
    try testing.expectError(error.OpenFailed, reader.journal('#'));
    try testing.expectError(error.OpenFailed, reader.journal('a'));
}
