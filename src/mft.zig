//! Raw master file table reading, for the size and timestamp the USN
//! enumeration does not carry.
//!
//! `FSCTL_ENUM_USN_DATA` hands back a name, a file reference and a parent
//! reference, which is everything the tree needs and nothing else. Sizes and
//! dates only exist in the file records themselves, so getting them means
//! reading `$MFT` off the volume and parsing NTFS structures by hand.
//!
//! Everything above `Volume` is pure: it turns bytes into numbers and never
//! touches a handle. That half is covered by tests built from records written
//! by hand, because the other half cannot run without an elevated process and
//! a real drive.

const std = @import("std");
const w = @import("win32.zig");

pub const Error = error{
    NotNtfs,
    BadGeometry,
    BadRecord,
    BadRunList,
    ReadFailed,
};

/// Windows counts 100 nanosecond ticks from 1601. Zero means the record did not
/// say, which is different from the epoch itself.
pub const FileTime = i64;

pub const Broken = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
};

/// Splits a file time into calendar pieces. Null when the record never said, or
/// when the value predates 1970 and is more likely garbage than a real date.
/// The result is in whatever zone the value is in, so convert before calling.
pub fn breakDown(ft: FileTime) ?Broken {
    if (ft <= 0) return null;
    // File times count from 1601 while the epoch helpers count from 1970.
    const unix = @divFloor(ft, 10_000_000) - 11_644_473_600;
    if (unix < 0) return null;

    const seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(unix) };
    const year_day = seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_time = seconds.getDaySeconds();
    return .{
        .year = year_day.year,
        .month = month_day.month.numeric(),
        .day = month_day.day_index + 1,
        .hour = day_time.getHoursIntoDay(),
        .minute = day_time.getMinutesIntoHour(),
    };
}

// ---- boot sector ----

/// The volume numbers every offset calculation needs, read from the first
/// sector. Everything here is in bytes except the cluster number.
pub const Geometry = struct {
    bytes_per_sector: u32,
    bytes_per_cluster: u32,
    bytes_per_record: u32,
    mft_start_cluster: u64,

    pub fn parse(boot: []const u8) Error!Geometry {
        if (boot.len < 0x50) return error.BadGeometry;
        if (!std.mem.eql(u8, boot[3..11], "NTFS    ")) return error.NotNtfs;

        const bytes_per_sector: u32 = std.mem.readInt(u16, boot[0x0B..0x0D], .little);
        const sectors_per_cluster: u32 = boot[0x0D];
        if (bytes_per_sector < 256 or bytes_per_sector > 8192) return error.BadGeometry;
        if (!std.math.isPowerOfTwo(bytes_per_sector)) return error.BadGeometry;
        if (sectors_per_cluster == 0 or !std.math.isPowerOfTwo(sectors_per_cluster)) {
            return error.BadGeometry;
        }

        // Positive counts clusters per record. Negative is the base two log of
        // the byte size, which is how a record smaller than a cluster is
        // written down.
        const raw: i8 = @bitCast(boot[0x40]);
        const bytes_per_cluster = bytes_per_sector * sectors_per_cluster;
        const bytes_per_record: u32 = if (raw > 0)
            @as(u32, @intCast(raw)) * bytes_per_cluster
        else if (raw >= -31 and raw < 0)
            @as(u32, 1) << @intCast(-raw)
        else
            return error.BadGeometry;

        if (bytes_per_record < 256 or bytes_per_record > 65536) return error.BadGeometry;
        if (bytes_per_record % bytes_per_sector != 0) return error.BadGeometry;

        return .{
            .bytes_per_sector = bytes_per_sector,
            .bytes_per_cluster = bytes_per_cluster,
            .bytes_per_record = bytes_per_record,
            .mft_start_cluster = std.mem.readInt(u64, boot[0x30..0x38], .little),
        };
    }
};

// ---- file records ----

const record_magic = "FILE";

const flag_in_use: u16 = 0x0001;
const flag_directory: u16 = 0x0002;

const attr_standard_information: u32 = 0x10;
const attr_data: u32 = 0x80;
const attr_end: u32 = 0xFFFF_FFFF;

/// Undoes the update sequence NTFS writes over the last two bytes of every
/// sector, so a torn write can be spotted. Without putting them back the tail
/// of each sector holds a check number instead of real data.
pub fn applyFixups(record: []u8, bytes_per_sector: u32) Error!void {
    if (record.len < 0x30) return error.BadRecord;
    if (!std.mem.eql(u8, record[0..4], record_magic)) return error.BadRecord;

    const usa_offset: usize = std.mem.readInt(u16, record[0x04..0x06], .little);
    const usa_count: usize = std.mem.readInt(u16, record[0x06..0x08], .little);
    if (usa_count == 0) return error.BadRecord;

    const sectors = usa_count - 1;
    if (sectors * bytes_per_sector > record.len) return error.BadRecord;
    if (usa_offset + usa_count * 2 > record.len) return error.BadRecord;

    const check = std.mem.readInt(u16, record[usa_offset..][0..2], .little);
    for (0..sectors) |i| {
        const tail = (i + 1) * bytes_per_sector - 2;
        if (std.mem.readInt(u16, record[tail..][0..2], .little) != check) return error.BadRecord;
        const put = std.mem.readInt(u16, record[usa_offset + (i + 1) * 2 ..][0..2], .little);
        std.mem.writeInt(u16, record[tail..][0..2], put, .little);
    }
}

/// What one file record says about the file it stands for.
pub const Info = struct {
    /// Position of this record in the table, which is the low 48 bits of the
    /// file reference the USN enumeration reports.
    number: u64 = 0,
    /// Bytes in the unnamed data stream. Zero for a directory, and also for a
    /// file whose data attribute lives in an extension record.
    size: u64 = 0,
    modified: FileTime = 0,
    created: FileTime = 0,
    in_use: bool = false,
    is_dir: bool = false,
    /// Non-zero when this record only extends another one, which is the record
    /// that owns the file's identity. Extensions carry no name of their own.
    extends: u64 = 0,
};

/// Reads a record whose fixups have already been put back. Records that are
/// free or unreadable come back with `in_use` clear rather than as an error,
/// because a table full of holes is normal.
pub fn readInfo(record: []const u8, number: u64) Error!Info {
    if (record.len < 0x30) return error.BadRecord;
    if (!std.mem.eql(u8, record[0..4], record_magic)) return error.BadRecord;

    const attrs_offset: usize = std.mem.readInt(u16, record[0x14..0x16], .little);
    const flags = std.mem.readInt(u16, record[0x16..0x18], .little);
    const used: usize = std.mem.readInt(u32, record[0x18..0x1C], .little);

    var info: Info = .{
        .number = number,
        .in_use = flags & flag_in_use != 0,
        .is_dir = flags & flag_directory != 0,
        .extends = std.mem.readInt(u64, record[0x20..0x28], .little) & 0x0000_FFFF_FFFF_FFFF,
    };
    if (!info.in_use) return info;
    if (attrs_offset >= record.len) return error.BadRecord;

    const limit = @min(if (used > record.len) record.len else used, record.len);
    var at = attrs_offset;
    while (at + 8 <= limit) {
        const kind = std.mem.readInt(u32, record[at..][0..4], .little);
        if (kind == attr_end) break;
        const length: usize = std.mem.readInt(u32, record[at + 4 ..][0..4], .little);
        // A zero length would spin forever, and one past the end would read
        // whatever follows the record in the buffer.
        if (length < 24 or at + length > limit) return error.BadRecord;
        const attr = record[at..][0..length];

        switch (kind) {
            attr_standard_information => readStandardInformation(attr, &info),
            attr_data => readDataSize(attr, &info),
            else => {},
        }
        at += length;
    }
    return info;
}

fn readStandardInformation(attr: []const u8, info: *Info) void {
    if (attr[8] != 0) return; // never non-resident in practice
    const value_len: usize = std.mem.readInt(u32, attr[0x10..0x14], .little);
    const value_off: usize = std.mem.readInt(u16, attr[0x14..0x16], .little);
    if (value_off + value_len > attr.len or value_len < 0x18) return;

    const value = attr[value_off..][0..value_len];
    info.created = std.mem.readInt(i64, value[0x00..0x08], .little);
    info.modified = std.mem.readInt(i64, value[0x08..0x10], .little);
}

fn readDataSize(attr: []const u8, info: *Info) void {
    // A named data attribute is an alternate stream, which is not the size
    // anybody means when they ask how big a file is.
    if (attr[9] != 0) return;

    if (attr[8] == 0) {
        info.size = std.mem.readInt(u32, attr[0x10..0x14], .little);
        return;
    }
    if (attr.len < 0x38) return;
    // Only the run holding the first cluster carries the real size. Later
    // pieces of a very fragmented file repeat the attribute with it zeroed.
    const start_vcn = std.mem.readInt(u64, attr[0x10..0x18], .little);
    if (start_vcn != 0) return;
    info.size = std.mem.readInt(u64, attr[0x30..0x38], .little);
}

// ---- data runs ----

/// One stretch of a file that is contiguous on disk.
pub const Run = struct {
    /// First cluster on disk. Meaningless when `sparse`.
    lcn: i64,
    clusters: u64,
    sparse: bool,
};

/// Decodes the run list an attribute uses to say where its clusters are. Each
/// run's position is written as a signed delta from the one before, so they
/// have to be walked in order.
pub fn parseRuns(bytes: []const u8, into: *std.ArrayList(Run), gpa: std.mem.Allocator) !void {
    var at: usize = 0;
    var lcn: i64 = 0;
    while (at < bytes.len) {
        const header = bytes[at];
        if (header == 0) return;
        at += 1;

        const length_size: usize = header & 0x0F;
        const offset_size: usize = header >> 4;
        if (length_size == 0 or length_size > 8 or offset_size > 8) return error.BadRunList;
        if (at + length_size + offset_size > bytes.len) return error.BadRunList;

        const clusters = readLittle(bytes[at..][0..length_size], false);
        at += length_size;

        // No offset field at all means the run is a hole with nothing behind it.
        if (offset_size == 0) {
            try into.append(gpa, .{ .lcn = 0, .clusters = @bitCast(clusters), .sparse = true });
            continue;
        }
        lcn += readLittle(bytes[at..][0..offset_size], true);
        at += offset_size;

        try into.append(gpa, .{ .lcn = lcn, .clusters = @bitCast(clusters), .sparse = false });
    }
}

/// Reads up to eight little endian bytes, sign extending when asked.
fn readLittle(bytes: []const u8, signed: bool) i64 {
    var value: u64 = 0;
    for (bytes, 0..) |b, i| value |= @as(u64, b) << @intCast(i * 8);
    if (!signed or bytes.len == 8) return @bitCast(value);

    const sign_bit = @as(u64, 1) << @intCast(bytes.len * 8 - 1);
    if (value & sign_bit != 0) {
        // Fill the rest with ones, which is what the shorter field stands for.
        value |= ~((@as(u64, 1) << @intCast(bytes.len * 8)) - 1);
    }
    return @bitCast(value);
}

pub const Placement = struct { lcn: i64, clusters: u64 };

/// Remembers how far through the run list a walk has got. A fragmented table
/// has tens of thousands of runs, and searching from the front for every one of
/// them turns a sequential read into quadratic work.
pub const Cursor = struct {
    run: usize = 0,
    /// First virtual cluster of `run`.
    starts_at: u64 = 0,
};

/// The run holding a given virtual cluster, and how many clusters follow it
/// contiguously. Null once the virtual cluster runs off the end or lands in a
/// hole. Carries on from `cursor`, which only ever moves forward.
pub fn locateFrom(runs: []const Run, vcn: u64, cursor: *Cursor) ?Placement {
    if (vcn < cursor.starts_at) cursor.* = .{};

    while (cursor.run < runs.len) {
        const run = runs[cursor.run];
        if (vcn < cursor.starts_at + run.clusters) {
            if (run.sparse) return null;
            const into = vcn - cursor.starts_at;
            return .{ .lcn = run.lcn + @as(i64, @intCast(into)), .clusters = run.clusters - into };
        }
        cursor.starts_at += run.clusters;
        cursor.run += 1;
    }
    return null;
}

pub fn locate(runs: []const Run, vcn: u64) ?Placement {
    var cursor: Cursor = .{};
    return locateFrom(runs, vcn, &cursor);
}

// ---- reading a real volume ----

/// A volume handle plus everything needed to find records on it. Opening one
/// reads the boot sector and then record zero, which is `$MFT` describing where
/// the rest of itself lives.
pub const Volume = struct {
    gpa: std.mem.Allocator,
    handle: w.HANDLE,
    geo: Geometry,
    runs: std.ArrayList(Run) = .empty,
    /// Bytes in the whole table, so the scan knows where to stop.
    bytes: u64 = 0,

    pub fn open(gpa: std.mem.Allocator, handle: w.HANDLE) !Volume {
        var boot: [512]u8 = undefined;
        try readRaw(handle, 0, &boot);
        const geo = try Geometry.parse(&boot);

        var self: Volume = .{ .gpa = gpa, .handle = handle, .geo = geo };
        errdefer self.deinit();

        // Record zero has to be read before the run list exists, so it is found
        // straight from the cluster the boot sector points at.
        const first = try gpa.alloc(u8, geo.bytes_per_record);
        defer gpa.free(first);
        try readRaw(handle, geo.mft_start_cluster * geo.bytes_per_cluster, first);
        try applyFixups(first, geo.bytes_per_sector);

        try self.readOwnRuns(first);
        for (self.runs.items) |run| self.bytes += run.clusters * geo.bytes_per_cluster;
        if (self.bytes == 0) return error.BadRunList;
        return self;
    }

    pub fn deinit(self: *Volume) void {
        self.runs.deinit(self.gpa);
    }

    pub fn records(self: *const Volume) u64 {
        return self.bytes / self.geo.bytes_per_record;
    }

    /// Pulls the run list out of record zero's unnamed data attribute.
    fn readOwnRuns(self: *Volume, record: []const u8) !void {
        const attrs_offset: usize = std.mem.readInt(u16, record[0x14..0x16], .little);
        var at = attrs_offset;
        while (at + 8 <= record.len) {
            const kind = std.mem.readInt(u32, record[at..][0..4], .little);
            if (kind == attr_end) break;
            const length: usize = std.mem.readInt(u32, record[at + 4 ..][0..4], .little);
            if (length < 24 or at + length > record.len) return error.BadRecord;
            const attr = record[at..][0..length];

            if (kind == attr_data and attr[9] == 0 and attr[8] != 0) {
                const run_offset: usize = std.mem.readInt(u16, attr[0x20..0x22], .little);
                if (run_offset >= attr.len) return error.BadRecord;
                try parseRuns(attr[run_offset..], &self.runs, self.gpa);
                return;
            }
            at += length;
        }
        return error.BadRunList;
    }

    /// Fills `buf` from virtual byte offset `at` in the table, crossing as many
    /// runs as it takes. Returns how much it managed, which is short only at
    /// the end or at a hole. `cursor` belongs to the caller and makes a walk
    /// forward through the table cost nothing per run.
    pub fn read(self: *const Volume, at: u64, buf: []u8, cursor: *Cursor) !usize {
        var filled: usize = 0;
        var pos = at;
        while (filled < buf.len) {
            const cluster = pos / self.geo.bytes_per_cluster;
            const into = pos % self.geo.bytes_per_cluster;
            const found = locateFrom(self.runs.items, cluster, cursor) orelse break;

            const contiguous = found.clusters * self.geo.bytes_per_cluster - into;
            const want: usize = @intCast(@min(contiguous, buf.len - filled));
            const disk = @as(u64, @intCast(found.lcn)) * self.geo.bytes_per_cluster + into;
            try readRaw(self.handle, disk, buf[filled..][0..want]);

            filled += want;
            pos += want;
        }
        return filled;
    }
};

/// A volume handle only reads at sector aligned offsets and sizes, which every
/// caller here satisfies by working in whole clusters.
fn readRaw(handle: w.HANDLE, at: u64, buf: []u8) Error!void {
    var moved: i64 = 0;
    if (w.SetFilePointerEx(handle, @bitCast(at), &moved, w.FILE_BEGIN) == 0) return error.ReadFailed;

    var done: usize = 0;
    while (done < buf.len) {
        var got: w.DWORD = 0;
        const want: w.DWORD = @intCast(buf.len - done);
        if (w.ReadFile(handle, buf.ptr + done, want, &got, null) == 0) return error.ReadFailed;
        if (got == 0) return error.ReadFailed;
        done += got;
    }
}

// ---- tests ----

const testing = std.testing;

/// Builds a boot sector with the numbers the parser cares about.
fn fakeBoot(bytes_per_sector: u16, sectors_per_cluster: u8, record_shift: i8, mft: u64) [512]u8 {
    var boot = std.mem.zeroes([512]u8);
    @memcpy(boot[3..11], "NTFS    ");
    std.mem.writeInt(u16, boot[0x0B..0x0D], bytes_per_sector, .little);
    boot[0x0D] = sectors_per_cluster;
    std.mem.writeInt(u64, boot[0x30..0x38], mft, .little);
    boot[0x40] = @bitCast(record_shift);
    return boot;
}

test "a file time turns into a date" {
    // 2024-01-01 00:00 is 13348540800 seconds after 1601.
    const d = breakDown(133_485_408_000_000_000).?;
    try testing.expectEqual(@as(u16, 2024), d.year);
    try testing.expectEqual(@as(u8, 1), d.month);
    try testing.expectEqual(@as(u8, 1), d.day);
    try testing.expectEqual(@as(u8, 0), d.hour);

    // Half past nine that evening.
    const evening = breakDown(133_485_408_000_000_000 + (21 * 60 + 30) * 600_000_000).?;
    try testing.expectEqual(@as(u8, 21), evening.hour);
    try testing.expectEqual(@as(u8, 30), evening.minute);
}

test "a missing or impossible file time has no date" {
    try testing.expect(breakDown(0) == null);
    try testing.expect(breakDown(-1) == null);
    // Before 1970, which no real file on an NTFS volume carries.
    try testing.expect(breakDown(1_000_000) == null);
}

test "geometry comes out of the boot sector" {
    const boot = fakeBoot(512, 8, -10, 786432);
    const geo = try Geometry.parse(&boot);
    try testing.expectEqual(@as(u32, 512), geo.bytes_per_sector);
    try testing.expectEqual(@as(u32, 4096), geo.bytes_per_cluster);
    // A negative count is a power of two in bytes, so -10 means 1024.
    try testing.expectEqual(@as(u32, 1024), geo.bytes_per_record);
    try testing.expectEqual(@as(u64, 786432), geo.mft_start_cluster);
}

test "a positive record count means whole clusters" {
    const boot = fakeBoot(512, 2, 2, 0);
    const geo = try Geometry.parse(&boot);
    try testing.expectEqual(@as(u32, 1024), geo.bytes_per_cluster);
    try testing.expectEqual(@as(u32, 2048), geo.bytes_per_record);
}

test "anything but NTFS is refused" {
    var boot = fakeBoot(512, 8, -10, 0);
    @memcpy(boot[3..11], "MSDOS5.0");
    try testing.expectError(error.NotNtfs, Geometry.parse(&boot));
}

test "impossible geometry is refused rather than trusted" {
    try testing.expectError(error.BadGeometry, Geometry.parse(&fakeBoot(999, 8, -10, 0)));
    try testing.expectError(error.BadGeometry, Geometry.parse(&fakeBoot(512, 0, -10, 0)));
    try testing.expectError(error.BadGeometry, Geometry.parse(&fakeBoot(512, 3, -10, 0)));
    // A record smaller than a sector cannot hold its own fixups.
    try testing.expectError(error.BadGeometry, Geometry.parse(&fakeBoot(1024, 1, -9, 0)));
}

/// A record of `sectors` sectors with the update sequence already written in,
/// so the last two bytes of each sector hold the check number.
fn fakeRecord(buf: []u8, bytes_per_sector: usize, check: u16, put: []const u16) void {
    @memset(buf, 0);
    @memcpy(buf[0..4], record_magic);
    std.mem.writeInt(u16, buf[0x04..0x06], 0x30, .little); // usa offset
    std.mem.writeInt(u16, buf[0x06..0x08], @intCast(put.len + 1), .little);
    std.mem.writeInt(u16, buf[0x30..0x32], check, .little);
    for (put, 0..) |value, i| {
        std.mem.writeInt(u16, buf[0x32 + i * 2 ..][0..2], value, .little);
        const tail = (i + 1) * bytes_per_sector - 2;
        std.mem.writeInt(u16, buf[tail..][0..2], check, .little);
    }
}

test "fixups put the real bytes back" {
    var record: [1024]u8 = undefined;
    fakeRecord(&record, 512, 0xABCD, &.{ 0x1122, 0x3344 });

    try applyFixups(&record, 512);
    try testing.expectEqual(@as(u16, 0x1122), std.mem.readInt(u16, record[510..512], .little));
    try testing.expectEqual(@as(u16, 0x3344), std.mem.readInt(u16, record[1022..1024], .little));
}

test "a record whose sectors disagree is a torn write" {
    var record: [1024]u8 = undefined;
    fakeRecord(&record, 512, 0xABCD, &.{ 0x1122, 0x3344 });
    std.mem.writeInt(u16, record[1022..1024], 0x0000, .little);
    try testing.expectError(error.BadRecord, applyFixups(&record, 512));
}

/// Lays out a record with a standard information attribute and a data one.
fn recordWith(buf: []u8, flags: u16, modified: i64, data: []const u8) void {
    @memset(buf, 0);
    @memcpy(buf[0..4], record_magic);
    std.mem.writeInt(u16, buf[0x04..0x06], 0x30, .little);
    std.mem.writeInt(u16, buf[0x06..0x08], 3, .little);
    std.mem.writeInt(u16, buf[0x14..0x16], 0x38, .little); // attributes start
    std.mem.writeInt(u16, buf[0x16..0x18], flags, .little);

    var at: usize = 0x38;
    // $STANDARD_INFORMATION, resident, 0x48 long around a 0x30 value that
    // starts 0x18 in, which is the shape NTFS actually writes.
    std.mem.writeInt(u32, buf[at..][0..4], attr_standard_information, .little);
    std.mem.writeInt(u32, buf[at + 4 ..][0..4], 0x48, .little);
    std.mem.writeInt(u32, buf[at + 0x10 ..][0..4], 0x30, .little);
    std.mem.writeInt(u16, buf[at + 0x14 ..][0..2], 0x18, .little);
    std.mem.writeInt(i64, buf[at + 0x18 + 0x08 ..][0..8], modified, .little);
    at += 0x48;

    @memcpy(buf[at..][0..data.len], data);
    at += data.len;

    std.mem.writeInt(u32, buf[at..][0..4], attr_end, .little);
    std.mem.writeInt(u32, buf[0x18..0x1C], @intCast(at + 4), .little);
}

/// A resident $DATA attribute holding `size` bytes of value.
fn residentData(buf: []u8, size: u32) []const u8 {
    @memset(buf, 0);
    std.mem.writeInt(u32, buf[0..4], attr_data, .little);
    std.mem.writeInt(u32, buf[4..8], 0x30, .little);
    std.mem.writeInt(u32, buf[0x10..0x14], size, .little);
    std.mem.writeInt(u16, buf[0x14..0x16], 0x18, .little);
    return buf[0..0x30];
}

/// A non-resident $DATA attribute claiming `size` bytes on disk.
fn nonResidentData(buf: []u8, size: u64, start_vcn: u64) []const u8 {
    @memset(buf, 0);
    std.mem.writeInt(u32, buf[0..4], attr_data, .little);
    std.mem.writeInt(u32, buf[4..8], 0x48, .little);
    buf[8] = 1;
    std.mem.writeInt(u64, buf[0x10..0x18], start_vcn, .little);
    std.mem.writeInt(u64, buf[0x30..0x38], size, .little);
    return buf[0..0x48];
}

test "a small file carries its size in the record" {
    var attr: [0x30]u8 = undefined;
    var record: [1024]u8 = undefined;
    recordWith(&record, flag_in_use, 132_000_000_000_000_000, residentData(&attr, 137));

    const info = try readInfo(&record, 42);
    try testing.expect(info.in_use);
    try testing.expect(!info.is_dir);
    try testing.expectEqual(@as(u64, 42), info.number);
    try testing.expectEqual(@as(u64, 137), info.size);
    try testing.expectEqual(@as(i64, 132_000_000_000_000_000), info.modified);
}

test "a big file carries its size in the attribute header" {
    var attr: [0x48]u8 = undefined;
    var record: [1024]u8 = undefined;
    recordWith(&record, flag_in_use, 1, nonResidentData(&attr, 4_294_967_296, 0));

    const info = try readInfo(&record, 7);
    try testing.expectEqual(@as(u64, 4_294_967_296), info.size);
}

test "a later piece of a fragmented file does not claim the size" {
    var attr: [0x48]u8 = undefined;
    var record: [1024]u8 = undefined;
    // Only the piece starting at cluster zero repeats the real size.
    recordWith(&record, flag_in_use, 1, nonResidentData(&attr, 4_294_967_296, 512));

    const info = try readInfo(&record, 7);
    try testing.expectEqual(@as(u64, 0), info.size);
}

test "a directory is marked and has no size" {
    var attr: [0x30]u8 = undefined;
    var record: [1024]u8 = undefined;
    recordWith(&record, flag_in_use | flag_directory, 5, residentData(&attr, 0));

    const info = try readInfo(&record, 5);
    try testing.expect(info.is_dir);
    try testing.expectEqual(@as(u64, 0), info.size);
}

test "a free record reports itself free without being read further" {
    var attr: [0x30]u8 = undefined;
    var record: [1024]u8 = undefined;
    recordWith(&record, 0, 99, residentData(&attr, 500));

    const info = try readInfo(&record, 1);
    try testing.expect(!info.in_use);
    try testing.expectEqual(@as(u64, 0), info.size);
}

test "an attribute claiming a silly length is refused" {
    var attr: [0x30]u8 = undefined;
    var record: [1024]u8 = undefined;
    recordWith(&record, flag_in_use, 1, residentData(&attr, 10));

    // A zero length would leave the walk going round forever.
    std.mem.writeInt(u32, record[0x38 + 4 ..][0..4], 0, .little);
    try testing.expectError(error.BadRecord, readInfo(&record, 1));

    recordWith(&record, flag_in_use, 1, residentData(&attr, 10));
    std.mem.writeInt(u32, record[0x38 + 4 ..][0..4], 999_999, .little);
    try testing.expectError(error.BadRecord, readInfo(&record, 1));
}

test "run offsets are deltas and can go backwards" {
    const gpa = testing.allocator;
    var runs: std.ArrayList(Run) = .empty;
    defer runs.deinit(gpa);

    // 0x21 0x18 0x34 0x12  ->  0x18 clusters at +0x1234
    // 0x11 0x08 0xF0       ->  8 clusters at -0x10 from there
    // 0x01 0x04            ->  4 sparse clusters
    // 0x00                 ->  end
    try parseRuns(&.{ 0x21, 0x18, 0x34, 0x12, 0x11, 0x08, 0xF0, 0x01, 0x04, 0x00 }, &runs, gpa);

    try testing.expectEqual(@as(usize, 3), runs.items.len);
    try testing.expectEqual(@as(i64, 0x1234), runs.items[0].lcn);
    try testing.expectEqual(@as(u64, 0x18), runs.items[0].clusters);
    try testing.expectEqual(@as(i64, 0x1234 - 0x10), runs.items[1].lcn);
    try testing.expect(!runs.items[1].sparse);
    try testing.expect(runs.items[2].sparse);
    try testing.expectEqual(@as(u64, 4), runs.items[2].clusters);
}

test "a truncated run list is refused rather than guessed at" {
    const gpa = testing.allocator;
    var runs: std.ArrayList(Run) = .empty;
    defer runs.deinit(gpa);
    try testing.expectError(error.BadRunList, parseRuns(&.{ 0x21, 0x18 }, &runs, gpa));
}

test "locating a cluster walks the runs in order" {
    const runs = [_]Run{
        .{ .lcn = 100, .clusters = 10, .sparse = false },
        .{ .lcn = 500, .clusters = 5, .sparse = false },
    };
    try testing.expectEqual(@as(i64, 100), locate(&runs, 0).?.lcn);
    try testing.expectEqual(@as(u64, 10), locate(&runs, 0).?.clusters);
    // Nine clusters in, one is left before the run ends.
    try testing.expectEqual(@as(i64, 109), locate(&runs, 9).?.lcn);
    try testing.expectEqual(@as(u64, 1), locate(&runs, 9).?.clusters);
    try testing.expectEqual(@as(i64, 500), locate(&runs, 10).?.lcn);
    try testing.expect(locate(&runs, 15) == null);
}

test "a cursor walks forward without rescanning the run list" {
    const runs = [_]Run{
        .{ .lcn = 100, .clusters = 4, .sparse = false },
        .{ .lcn = 200, .clusters = 4, .sparse = false },
        .{ .lcn = 300, .clusters = 4, .sparse = false },
    };
    var cursor: Cursor = .{};

    try testing.expectEqual(@as(i64, 100), locateFrom(&runs, 0, &cursor).?.lcn);
    try testing.expectEqual(@as(usize, 0), cursor.run);
    // Cluster 5 is one into the second run, which starts at cluster 4.
    try testing.expectEqual(@as(i64, 201), locateFrom(&runs, 5, &cursor).?.lcn);
    try testing.expectEqual(@as(usize, 1), cursor.run);
    try testing.expectEqual(@as(i64, 300), locateFrom(&runs, 8, &cursor).?.lcn);
    try testing.expectEqual(@as(usize, 2), cursor.run);
    try testing.expect(locateFrom(&runs, 12, &cursor) == null);

    // Going backwards is allowed, it just starts the walk over.
    try testing.expectEqual(@as(i64, 100), locateFrom(&runs, 0, &cursor).?.lcn);
    try testing.expectEqual(@as(usize, 0), cursor.run);
}

test "a cursor gives the same answers as searching from the front" {
    const runs = [_]Run{
        .{ .lcn = 10, .clusters = 3, .sparse = false },
        .{ .lcn = 0, .clusters = 2, .sparse = true },
        .{ .lcn = 40, .clusters = 5, .sparse = false },
    };
    var cursor: Cursor = .{};
    for (0..12) |vcn| {
        const walked = locateFrom(&runs, vcn, &cursor);
        const searched = locate(&runs, vcn);
        try testing.expectEqual(searched == null, walked == null);
        if (searched) |want| try testing.expectEqual(want.lcn, walked.?.lcn);
    }
}

test "a hole has nothing behind it to read" {
    const runs = [_]Run{
        .{ .lcn = 0, .clusters = 4, .sparse = true },
        .{ .lcn = 90, .clusters = 2, .sparse = false },
    };
    try testing.expect(locate(&runs, 1) == null);
    try testing.expectEqual(@as(i64, 90), locate(&runs, 4).?.lcn);
}
