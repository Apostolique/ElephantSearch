//! File and folder icons, out of the shell's own image list.
//!
//! Explorer draws a file's icon by asking the shell what it is, and the shell
//! answers two very different ways. For nearly everything it reads the
//! extension out of the registry, which costs nothing and can happen inside a
//! paint. For the handful of kinds that carry their own icon -- programs,
//! shortcuts, icon files -- it opens the file and pulls a resource out of it,
//! which is a disk read. Forty of those inside one paint is how a list turns
//! to treacle, and this list repaints on every keystroke.
//!
//! So the cheap answer is given straight away and the expensive one is asked
//! for on a worker thread. A program shows the generic program icon for as
//! long as that takes and then quietly becomes itself, which is what Everything
//! does and what anyone scrolling fast would want anyway: the rows they flew
//! past never cost a disk read at all.
//!
//! Nothing here is ever asked for a row that is not about to be drawn, so the
//! caches only ever grow to hold what somebody actually looked at.

const std = @import("std");
const w = @import("win32.zig");
const ui = @import("win32_ui.zig");

/// Waiting on the worker. The row draws with its extension's icon meanwhile.
const pending: i32 = -1;
/// The shell would not answer for this file -- it is gone, or locked, or its
/// icon will not load -- so the extension's icon is the final answer and there
/// is no point asking again.
const unreadable: i32 = -2;
/// A drive nobody has drawn yet.
const unasked: i32 = -1;

/// Requests in flight. About two screens' worth: enough that scrolling a page
/// at a time never drops one, short enough that holding page-down does.
const queue_len: usize = 32;

/// Longest path the worker will look up, in UTF-16 units. Past this the
/// extension's icon stands, which for a path this deep is what Explorer would
/// have trouble showing too.
const path_len: usize = 320;

/// Longest extension worth keeping a cache entry for. Anything longer is a
/// file name with dots in it rather than a type the shell knows.
const ext_len: usize = 32;

/// Caps on what the two caches will grow to. A drive with a hundred thousand
/// distinct extensions on it is not a drive whose icons anyone is studying.
const max_ext: usize = 4096;
const max_entries: usize = 16384;

/// Extensions whose icon is the file's own rather than its type's. The shell
/// decides this by looking for a `%1` default icon in the registry, which
/// would be another registry read per extension to find out; this is the list
/// that read would come back with on any Windows.
const per_file = [_][]const u8{
    ".exe", ".lnk", ".ico", ".cur", ".ani", ".scr", ".msc", ".cpl", ".url",
};

const Request = struct {
    entry: u32,
    len: usize,
    path: [path_len]u16,
};

pub const Icons = struct {
    gpa: std.mem.Allocator,

    /// The shell's small image list. Shared across the process and not ours to
    /// destroy, which is why it is only ever borrowed.
    list: ?ui.HANDLE = null,
    icon_cx: i32 = 0,
    icon_cy: i32 = 0,

    /// What a row falls back to: the generic folder and the unknown file.
    folder: i32 = 0,
    file: i32 = 0,
    /// One per drive letter, filled in as the roots get drawn. There are only
    /// ever a handful of these and they only show on the first screen of an
    /// empty query, but a drive drawn as a folder is the one wrong icon
    /// somebody would see before they had typed anything.
    by_drive: [26]i32 = @splat(unasked),

    /// Extension to image index, both lowercased and owned here, because a
    /// name is a slice of the index's blob and that moves as it grows.
    /// Only ever touched by the thread that draws.
    by_ext: std.StringHashMapUnmanaged(i32) = .empty,

    /// Files whose icon is their own. Written by both threads, so it is behind
    /// the lock with the queue.
    by_entry: std.AutoHashMapUnmanaged(u32, i32) = .empty,

    lock: w.Lock = .{},
    wake: w.Signal = .{},
    queue: [queue_len]Request = undefined,
    queued: usize = 0,
    running: bool = true,
    thread: ?std.Thread = null,

    /// Where to say that an icon has arrived, and whether that has been said
    /// already. One message per repaint rather than one per icon: a screenful
    /// arriving together would otherwise ask for thirty repaints of the same
    /// thirty rows.
    hwnd: ?ui.HANDLE = null,
    message: u32 = 0,
    told: std.atomic.Value(bool) = .init(false),

    pub fn init(gpa: std.mem.Allocator) Icons {
        return .{ .gpa = gpa };
    }

    /// Borrows the shell's image list and starts the worker. Everything here
    /// is allowed to fail: without the list the rows simply have no icons,
    /// which is where this program was before.
    pub fn start(self: *Icons, hwnd: ui.HANDLE, message: u32) void {
        self.hwnd = hwnd;
        self.message = message;

        var info: ui.ShFileInfo = .{};
        // The one call that both hands over the image list and says which
        // index the generic folder sits at, so there is no second lookup.
        const name = std.unicode.utf8ToUtf16LeStringLiteral("folder");
        const got = ui.SHGetFileInfoW(
            name,
            ui.FILE_ATTRIBUTE_DIRECTORY,
            &info,
            @sizeOf(ui.ShFileInfo),
            ui.SHGFI_SYSICONINDEX | ui.SHGFI_SMALLICON | ui.SHGFI_USEFILEATTRIBUTES,
        );
        if (got == 0) return;
        self.folder = info.icon_index;

        // The list that call hands back is a fixed sixteen pixels, which is
        // half an icon on a scaled display. SHIL_SYSSMALL is the same icons at
        // whatever size the system is actually drawing small ones, and the
        // indices are the same in both, so the one already in hand stands in
        // wherever it is missing.
        var scaled: ?ui.HANDLE = null;
        self.list = if (ui.SHGetImageList(ui.SHIL_SYSSMALL, &ui.IID_IImageList, &scaled) >= 0)
            scaled orelse @ptrFromInt(got)
        else
            @ptrFromInt(got);

        if (self.list) |list| {
            _ = ui.ImageList_GetIconSize(list, &self.icon_cx, &self.icon_cy);
        }
        self.file = lookUpNarrow(unknown_file) orelse 0;

        self.thread = std.Thread.spawn(.{}, work, .{self}) catch null;
    }

    pub fn deinit(self: *Icons) void {
        if (self.thread) |t| {
            {
                self.lock.acquire();
                defer self.lock.release();
                self.running = false;
            }
            self.wake.wake();
            t.join();
            self.thread = null;
        }

        var it = self.by_ext.keyIterator();
        while (it.next()) |key| self.gpa.free(key.*);
        self.by_ext.deinit(self.gpa);
        self.by_entry.deinit(self.gpa);
    }

    /// The image index for a row, and a request for a better one when this
    /// file's icon has to be read off the disk first. Called once per row
    /// being drawn, so everything on this path is a hash lookup or less.
    pub fn indexFor(self: *Icons, entry: u32, is_dir: bool, name: []const u8, path: []const u8) i32 {
        if (self.list == null) return 0;
        if (is_dir) return self.folder;

        const ext = extensionOf(name);
        const generic = self.forExtension(ext);
        if (!ownIcon(ext)) return generic;

        self.lock.acquire();
        defer self.lock.release();

        if (self.by_entry.get(entry)) |known| {
            return if (known >= 0) known else generic;
        }
        if (self.by_entry.count() >= max_entries) return generic;

        // Claiming the slot before queueing is what stops the next repaint,
        // a frame later, asking for the same file again.
        self.by_entry.put(self.gpa, entry, pending) catch return generic;
        self.enqueue(entry, path);
        return generic;
    }

    /// The icon for a whole drive, which is neither a folder nor a file. This
    /// one asks about the real letter rather than a made up name, so a drive
    /// comes out looking like the kind of drive it is. It is a local volume by
    /// the time anything here has heard of it, and there are at most a couple
    /// of dozen, each asked for once.
    pub fn forDrive(self: *Icons, letter: u8) i32 {
        if (self.list == null) return 0;
        const upper = std.ascii.toUpper(letter);
        if (upper < 'A' or upper > 'Z') return self.folder;

        const slot = &self.by_drive[upper - 'A'];
        if (slot.* != unasked) return slot.*;

        const root = [_]u16{ upper, ':', '\\', 0 };
        slot.* = lookUpFile(root[0..3 :0]) orelse self.folder;
        return slot.*;
    }

    /// The icon for a type rather than for a file, which the shell answers
    /// from the registry without opening anything.
    fn forExtension(self: *Icons, ext: []const u8) i32 {
        if (ext.len == 0) return self.file;

        var lowered: [ext_len]u8 = undefined;
        for (ext, lowered[0..ext.len]) |c, *o| o.* = std.ascii.toLower(c);
        const key = lowered[0..ext.len];

        if (self.by_ext.get(key)) |known| return known;
        if (self.by_ext.count() >= max_ext) return self.file;

        // A made up name carrying the real extension. `SHGFI_USEFILEATTRIBUTES`
        // means nothing is looked for on disk, so it does not have to exist.
        var fake: [ext_len + 2]u8 = undefined;
        fake[0] = 'x';
        @memcpy(fake[1..][0..key.len], key);

        const found = lookUpNarrow(fake[0 .. key.len + 1]) orelse self.file;

        const owned = self.gpa.dupe(u8, key) catch return found;
        self.by_ext.put(self.gpa, owned, found) catch {
            self.gpa.free(owned);
        };
        return found;
    }

    /// Adds a request, dropping the oldest when there is no room. The oldest
    /// is the row furthest from wherever the list is now, since requests only
    /// arrive from rows being drawn.
    fn enqueue(self: *Icons, entry: u32, path: []const u8) void {
        var req: Request = .{ .entry = entry, .len = 0, .path = undefined };
        const n = std.unicode.wtf8ToWtf16Le(req.path[0 .. req.path.len - 1], path) catch return;
        req.path[n] = 0;
        req.len = n;

        if (self.queued == self.queue.len) {
            std.mem.copyForwards(Request, self.queue[0 .. self.queue.len - 1], self.queue[1..]);
            self.queued -= 1;
        }
        self.queue[self.queued] = req;
        self.queued += 1;
        self.wake.wake();
    }

    fn work(self: *Icons) void {
        // The shell wants COM up on whatever thread asks it for an icon, since
        // pulling one out of a file can mean loading somebody's extension to
        // do it. S_FALSE means it already was, and both still owe an
        // uninitialise.
        const com = w.CoInitializeEx(null, w.COINIT_APARTMENTTHREADED);
        defer if (com >= 0) w.CoUninitialize();

        while (true) {
            var req: Request = undefined;
            {
                self.lock.acquire();
                defer self.lock.release();
                while (self.running and self.queued == 0) self.wake.wait(&self.lock);
                if (!self.running) return;
                // Newest first. Somebody scrolling leaves a trail of requests
                // for rows that are no longer on screen, and the row they are
                // looking at now is the one worth the disk.
                self.queued -= 1;
                req = self.queue[self.queued];
            }

            const found = lookUpFile(req.path[0..req.len :0]) orelse unreadable;

            {
                self.lock.acquire();
                defer self.lock.release();
                // The slot was put there before the request was made, so this
                // only ever writes over `pending` and never allocates.
                if (self.by_entry.getPtr(req.entry)) |slot| slot.* = found;
            }

            self.announce();
        }
    }

    /// Tells the window an icon has landed, at most once until it has looked.
    fn announce(self: *Icons) void {
        const hwnd = self.hwnd orelse return;
        if (self.told.swap(true, .acq_rel)) return;
        if (ui.PostMessageW(hwnd, self.message, 0, 0) == 0) self.told.store(false, .release);
    }

    /// Called by the window once it has repainted, which lets the next icon
    /// to arrive ask for another.
    pub fn seen(self: *Icons) void {
        self.told.store(false, .release);
    }
};

/// The icon the shell holds for a file that really is there, which means
/// opening it. Only ever called from the worker.
fn lookUpFile(path: [:0]const u16) ?i32 {
    var info: ui.ShFileInfo = .{};
    const got = ui.SHGetFileInfoW(
        path.ptr,
        0,
        &info,
        @sizeOf(ui.ShFileInfo),
        ui.SHGFI_SYSICONINDEX | ui.SHGFI_SMALLICON,
    );
    return if (got == 0) null else info.icon_index;
}

/// The icon for a name, answered from the registry without anything being
/// opened. The name does not have to exist and here it never does.
fn lookUpNarrow(name: []const u8) ?i32 {
    var wide: [ext_len + 32]u16 = undefined;
    const n = std.unicode.wtf8ToWtf16Le(wide[0 .. wide.len - 1], name) catch return null;
    wide[n] = 0;

    var info: ui.ShFileInfo = .{};
    const got = ui.SHGetFileInfoW(
        wide[0..n :0].ptr,
        ui.FILE_ATTRIBUTE_NORMAL,
        &info,
        @sizeOf(ui.ShFileInfo),
        ui.SHGFI_SYSICONINDEX | ui.SHGFI_SMALLICON | ui.SHGFI_USEFILEATTRIBUTES,
    );
    return if (got == 0) null else info.icon_index;
}

/// A name with no extension the shell could know, which is how the icon for
/// "some file, kind unknown" gets asked for.
const unknown_file = "x.uNkNoWn-ElEpHaNt";

/// The dot and everything after it, the way `PathFindExtension` reads a name,
/// so `.gitignore` is an extension in its own right rather than a name without
/// one. Empty when there is no dot or the tail is too long to be a type.
fn extensionOf(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "";
    const ext = name[dot..];
    return if (ext.len > ext_len) "" else ext;
}

/// Whether drawing this file needs its path built. Almost nothing does, and
/// the caller is on the drawing thread, so it is worth asking before walking
/// a parent chain for a row that was only ever going to get its type's icon.
pub fn needsFile(name: []const u8) bool {
    return ownIcon(extensionOf(name));
}

/// Every name on the list is four characters, so checking the length first
/// settles nearly every file without a comparison at all.
fn ownIcon(ext: []const u8) bool {
    if (ext.len != 4) return false;
    for (per_file) |candidate| {
        if (std.ascii.eqlIgnoreCase(ext, candidate)) return true;
    }
    return false;
}

// ---- tests ----

const testing = std.testing;

test "an extension is the last dot onwards" {
    try testing.expectEqualStrings(".zig", extensionOf("main.zig"));
    try testing.expectEqualStrings(".gz", extensionOf("archive.tar.gz"));
    try testing.expectEqualStrings(".gitignore", extensionOf(".gitignore"));
    try testing.expectEqualStrings("", extensionOf("Makefile"));
    try testing.expectEqualStrings("", extensionOf(""));
}

test "an extension too long to be a type is not one" {
    const long = "file." ++ "x" ** (ext_len + 1);
    try testing.expectEqualStrings("", extensionOf(long));
}

test "only the kinds that carry their own icon get a disk read" {
    try testing.expect(ownIcon(".exe"));
    try testing.expect(ownIcon(".EXE"));
    try testing.expect(ownIcon(".lnk"));
    try testing.expect(!ownIcon(".zig"));
    try testing.expect(!ownIcon(".txt"));
    try testing.expect(!ownIcon(""));
    try testing.expect(!ownIcon(".executable"));
}

test "every name on the per file list is four characters" {
    // `ownIcon` rejects on length before it compares, so a five character
    // entry added here would never match anything.
    for (per_file) |ext| try testing.expectEqual(@as(usize, 4), ext.len);
}
