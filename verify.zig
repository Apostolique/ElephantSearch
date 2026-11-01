//! Checks the master file table reader against a real drive, which the unit
//! tests cannot do: they work from records written by hand, and the thing most
//! worth knowing is whether a genuine volume parses the same way.
//!
//! Run with `zig build verify`. It needs a volume it can open, which means an
//! elevated terminal or the installed service, and it skips rather than fails
//! without one so that a plain checkout still passes. With the service
//! installed and no elevation it checks the service's path end to end.
//!
//! It is a program rather than a test because the build runner marks any test
//! that writes to stderr as a failed command, and this one's whole point is the
//! report it prints. It exits 1 when anything disagrees.

const std = @import("std");
const w = @import("src/win32.zig");
const idx = @import("src/index.zig");
const ntfs = @import("src/ntfs.zig");
const sizer_mod = @import("src/sizer.zig");
const pipe = @import("src/pipe.zig");
const shell = @import("src/shell.zig");

/// Files compared against the file system. Enough to catch a misread field,
/// few enough that the check stays quick.
const spot_checks = 200;

pub fn main(init: std.process.Init) !u8 {
    // Its own allocator so that a leak still fails the check, the way the
    // testing allocator made it when this was a test.
    var debug: std.heap.DebugAllocator(.{}) = .init;
    const gpa = debug.allocator();

    var out_buf: [4096]u8 = undefined;
    var out_file = std.Io.File.stdout().writer(init.io, &out_buf);
    const out = &out_file.interface;

    const passed = try check(gpa, out);
    try out.flush();

    if (debug.deinit() == .leak) {
        try out.writeAll("memory leaked\n");
        try out.flush();
        return 1;
    }
    return if (passed) 0 else 1;
}

fn check(gpa: std.mem.Allocator, out: *std.Io.Writer) !bool {
    var index = idx.Index.init(gpa);
    defer index.deinit();

    const choice = pipe.choose(gpa, shell.isElevated(), null);
    try out.print("reading {s}\n", .{if (choice.service == .used) "through the service" else "the volumes directly"});
    try out.flush();
    const reader = try choice.source.open(gpa);
    defer reader.close();

    var letter_buf: [26]u8 = undefined;
    const drives = ntfs.ntfsDrives(&letter_buf);
    if (drives.len == 0) {
        try out.writeAll("no NTFS volume to check\n");
        return true;
    }

    // Later letters first, because the system drive is both the slowest to read
    // and the least interesting one to prove the parser on.
    var scanned: ?u8 = null;
    var back = drives.len;
    while (back > 0) {
        back -= 1;
        const letter = drives[back];
        const stats = ntfs.scanVolume(&index, reader, letter) catch continue;
        try out.print("{c}: {d} entries in {d} ms\n", .{ letter, stats.entries, stats.millis });
        try out.flush();
        scanned = letter;
        break;
    }
    if (scanned == null) {
        try out.writeAll("no volume could be opened, run elevated or install the service to check this\n");
        return true;
    }
    try index.orderDepthFirst();

    var sizer = sizer_mod.Sizer.init(gpa, &index, choice.source);
    sizer.start();
    while (!sizer.progress().finished) w.Sleep(100);
    sizer.stop();

    const pass = sizer.progress();
    try out.print("filled {d} of {d} in {d} ms, {d} bytes read\n", .{
        pass.filled,
        pass.wanted,
        pass.millis,
        pass.scanned,
    });
    if (pass.trouble.len > 0) try out.print("trouble: {s}\n", .{pass.trouble});
    try out.flush();

    // The volume root has no record of its own, so it is the one entry that
    // never gets filled.
    if (pass.filled + 1 < pass.wanted) {
        try out.writeAll("the size pass left entries unfilled\n");
        return false;
    }

    const slice = index.entries.slice();
    var checked: usize = 0;
    var agreed: usize = 0;
    var path_buf: [32 * 1024]u8 = undefined;

    for (0..index.count()) |raw| {
        if (checked >= spot_checks) break;
        const i: u32 = @intCast(raw);
        if (index.isDir(i) or slice.items(.modified)[i] == 0) continue;

        const path = index.path(i, &path_buf);
        // A file deleted between the scan and now is not a disagreement.
        const found = ntfs.statPath(gpa, path) orelse continue;
        checked += 1;
        if (found.size == slice.items(.size)[i] and found.modified == slice.items(.modified)[i]) {
            agreed += 1;
            continue;
        }
        try out.print("  differs: {s}\n    table {d} bytes at {d}\n    disk  {d} bytes at {d}\n", .{
            path,
            slice.items(.size)[i],
            slice.items(.modified)[i],
            found.size,
            found.modified,
        });
    }

    try out.print("checked {d} files against the file system, {d} agreed\n", .{ checked, agreed });
    if (checked == 0) {
        try out.writeAll("no file was left to compare\n");
        return false;
    }
    return checked == agreed;
}
