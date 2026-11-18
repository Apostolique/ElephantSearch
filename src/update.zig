//! Asking GitHub for a newer release and putting it in place of this one.
//!
//! The new files land in the folder this program runs from, so a pin on the
//! taskbar and the Explorer menu entry keep pointing at the right place.
//! Windows won't overwrite a program that is running while it will rename
//! one, so each file moves aside to `.old` first and the next start deletes
//! those.

const std = @import("std");
const build_options = @import("build_options");
const w = @import("win32.zig");

const Io = std.Io;
const L = std.unicode.utf8ToUtf16LeStringLiteral;

pub const current = build_options.version;

const api_host = "api.github.com";
const latest_path = "/repos/Apostolique/ElephantSearch/releases/latest";

/// Where the download is unpacked, inside the program's folder so that moving
/// the files into place is a rename rather than a copy across drives.
const staging = ".update";

/// The release notes and the list of files run to a few kilobytes while the
/// zip is about 2 MB. Anything far past either is not what was asked for.
const max_listing: usize = 1 << 20;
const max_zip: usize = 64 << 20;

pub const Release = struct {
    arena: std.heap.ArenaAllocator,
    /// Without the `v` the tag starts with.
    version: []const u8,
    url: []const u8,
    /// Lowercase hex of the zip's sha256, as GitHub lists it.
    sha256: [64]u8,

    pub fn deinit(self: *Release) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// The latest release when it is newer than this program, null when this is
/// already the latest.
pub fn check(gpa: std.mem.Allocator) !?Release {
    const body = try get(gpa, api_host, latest_path, max_listing);
    defer gpa.free(body);
    var release = try parse(gpa, body);
    if (!try isNewer(release.version, current)) {
        release.deinit();
        return null;
    }
    return release;
}

/// Downloads `release`, checks it against the sha256 GitHub lists for it, and
/// swaps its files in for the ones next to this program.
pub fn apply(gpa: std.mem.Allocator, io: Io, release: *const Release) !void {
    const dir_path = try programFolder(gpa);
    defer gpa.free(dir_path);
    var app = try Io.Dir.openDirAbsolute(io, dir_path, .{});
    defer app.close(io);

    const where = try split(release.url);
    const zip = try get(gpa, where.host, where.path, max_zip);
    defer gpa.free(zip);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(zip, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &hex, &release.sha256)) return error.Corrupt;

    app.deleteTree(io, staging) catch {};
    defer app.deleteTree(io, staging) catch {};
    var stage = try app.createDirPathOpen(io, staging, .{});
    defer stage.close(io);
    try unzip(gpa, io, stage, zip);

    const from = try std.fmt.allocPrint(gpa, "{s}\\" ++ staging ++ "\\files", .{dir_path});
    defer gpa.free(from);
    try swap(gpa, io, from, dir_path);
}

/// Deletes what an update moved aside, now that nothing runs from it. A file
/// still in use stays until the next start.
pub fn cleanUp(gpa: std.mem.Allocator, io: Io) void {
    const dir_path = programFolder(gpa) catch return;
    defer gpa.free(dir_path);
    var app = Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return;
    defer app.close(io);
    clearOld(gpa, io, app);
    app.deleteTree(io, staging) catch {};
}

/// What went wrong, in words. Null for an error with nothing better to say
/// than its own name.
pub fn describe(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.Offline => "could not reach GitHub",
        error.BadStatus => "GitHub turned the request down",
        error.TooBig => "GitHub sent back more than a release should be",
        error.NoAsset => "the latest release has no zip for Windows",
        error.NoDigest => "GitHub lists no checksum for the latest release",
        error.BadVersion => "the latest release has a version this can't read",
        error.Corrupt => "the download doesn't match its checksum",
        error.AccessDenied, error.PermissionDenied, error.FileBusy => "the files next to this program can't be replaced, an older copy may still be running",
        else => null,
    };
}

// ---- reading the release ----

/// The part of GitHub's answer this needs. Drafts and prereleases never come
/// back from `/releases/latest`.
const Listing = struct {
    tag_name: []const u8,
    assets: []const Asset,

    const Asset = struct {
        name: []const u8,
        browser_download_url: []const u8,
        digest: ?[]const u8 = null,
    };
};

fn parse(gpa: std.mem.Allocator, body: []const u8) !Release {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    // Copied, since the body is freed while the release is still in use.
    const listing = try std.json.parseFromSliceLeaky(Listing, a, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    const version = if (std.mem.startsWith(u8, listing.tag_name, "v")) listing.tag_name[1..] else listing.tag_name;
    _ = std.SemanticVersion.parse(version) catch return error.BadVersion;

    const want = try std.fmt.allocPrint(a, "ElephantSearch-{s}-windows-x64.zip", .{version});
    for (listing.assets) |asset| {
        if (!std.mem.eql(u8, asset.name, want)) continue;
        const digest = asset.digest orelse return error.NoDigest;
        const prefix = "sha256:";
        if (!std.mem.startsWith(u8, digest, prefix) or digest.len != prefix.len + 64) return error.NoDigest;
        var release: Release = .{
            .arena = undefined,
            .version = version,
            .url = asset.browser_download_url,
            .sha256 = undefined,
        };
        for (&release.sha256, digest[prefix.len..]) |*out, c| out.* = std.ascii.toLower(c);
        release.arena = arena;
        return release;
    }
    return error.NoAsset;
}

fn isNewer(latest: []const u8, than: []const u8) !bool {
    const a = std.SemanticVersion.parse(latest) catch return error.BadVersion;
    const b = std.SemanticVersion.parse(than) catch return error.BadVersion;
    return a.order(b) == .gt;
}

const Where = struct { host: []const u8, path: []const u8 };

/// Only https, since what comes back gets run.
fn split(url: []const u8) !Where {
    const scheme = "https://";
    if (!std.mem.startsWith(u8, url, scheme)) return error.NoAsset;
    const rest = url[scheme.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.NoAsset;
    if (slash == 0) return error.NoAsset;
    return .{ .host = rest[0..slash], .path = rest[slash..] };
}

// ---- the request ----

/// The whole body of an https GET. WinHTTP follows the redirect GitHub
/// answers a download with, and goes through whatever proxy Windows is set up
/// with.
fn get(gpa: std.mem.Allocator, host: []const u8, path: []const u8, limit: usize) ![]u8 {
    const host_w = try std.unicode.wtf8ToWtf16LeAllocZ(gpa, host);
    defer gpa.free(host_w);
    const path_w = try std.unicode.wtf8ToWtf16LeAllocZ(gpa, path);
    defer gpa.free(path_w);

    // GitHub refuses a request that doesn't name what sent it.
    const session = w.WinHttpOpen(L("ElephantSearch/" ++ current), w.WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, null, null, 0) orelse
        return error.Offline;
    defer _ = w.WinHttpCloseHandle(session);
    const connection = w.WinHttpConnect(session, host_w, w.INTERNET_DEFAULT_HTTPS_PORT, 0) orelse return error.Offline;
    defer _ = w.WinHttpCloseHandle(connection);
    const request = w.WinHttpOpenRequest(connection, L("GET"), path_w, null, null, null, w.WINHTTP_FLAG_SECURE) orelse
        return error.Offline;
    defer _ = w.WinHttpCloseHandle(request);

    const headers = L("Accept: application/vnd.github+json\r\n");
    if (w.WinHttpSendRequest(request, headers, headers.len, null, 0, 0, 0) == 0) return error.Offline;
    if (w.WinHttpReceiveResponse(request, null) == 0) return error.Offline;

    var status: w.DWORD = 0;
    var size: w.DWORD = @sizeOf(w.DWORD);
    if (w.WinHttpQueryHeaders(request, w.WINHTTP_QUERY_STATUS_CODE | w.WINHTTP_QUERY_FLAG_NUMBER, null, &status, &size, null) == 0) {
        return error.Offline;
    }
    if (status != 200) return error.BadStatus;

    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(gpa);
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        var got: w.DWORD = 0;
        if (w.WinHttpReadData(request, &chunk, chunk.len, &got) == 0) return error.Offline;
        if (got == 0) break;
        if (body.items.len + got > limit) return error.TooBig;
        try body.appendSlice(gpa, chunk[0..got]);
    }
    return body.toOwnedSlice(gpa);
}

// ---- putting the files in place ----

/// Unpacks into `files`, taking out the one folder the release zip wraps
/// everything in.
fn unzip(gpa: std.mem.Allocator, io: Io, stage: Io.Dir, zip: []const u8) !void {
    try stage.writeFile(io, .{ .sub_path = "release.zip", .data = zip });
    var raw = try stage.createDirPathOpen(io, "unpacked", .{});
    defer raw.close(io);

    var diagnostics: std.zip.Diagnostics = .{ .allocator = gpa };
    defer diagnostics.deinit();
    {
        const file = try stage.openFile(io, "release.zip", .{});
        defer file.close(io);
        var buf: [4096]u8 = undefined;
        var reader = file.reader(io, &buf);
        try std.zip.extract(raw, &reader, .{ .diagnostics = &diagnostics });
    }

    const root = if (diagnostics.root_dir.len > 0) diagnostics.root_dir else ".";
    try Io.Dir.rename(raw, root, stage, "files", io);
}

const Moved = struct {
    name: []const u8,
    /// Whether there was a file by that name to move aside first.
    had_old: bool,
};

/// Moves every file in the folder `from` into the folder `to`, the one
/// already there moving aside to `.old`. Puts the old ones back if any of it
/// fails, so a half done swap never leaves a new window next to an old
/// service installer. Both are absolute paths.
pub fn swap(gpa: std.mem.Allocator, io: Io, from: []const u8, to: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var names: std.ArrayList([]const u8) = .empty;
    {
        var dir = try Io.Dir.openDirAbsolute(io, from, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            try names.append(a, try a.dupe(u8, entry.name));
        }
    }

    var moved: std.ArrayList(Moved) = .empty;
    errdefer for (moved.items) |m| {
        remove(a, to, m.name) catch {};
        if (m.had_old) {
            const old = std.fmt.allocPrint(a, "{s}.old", .{m.name}) catch continue;
            move(a, to, old, to, m.name) catch {};
        }
    };

    for (names.items) |name| {
        const old = try std.fmt.allocPrint(a, "{s}.old", .{name});
        remove(a, to, old) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        };
        var had_old = true;
        move(a, to, name, to, old) catch |e| switch (e) {
            error.FileNotFound => had_old = false,
            else => return e,
        };
        move(a, from, name, to, name) catch |e| {
            if (had_old) move(a, to, old, to, name) catch {};
            return e;
        };
        try moved.append(a, .{ .name = name, .had_old = had_old });
    }
}

/// `MoveFileExW` rather than `Io.Dir.rename`, which opens the file for
/// writing first and so can't move a program that is running.
fn move(a: std.mem.Allocator, from_dir: []const u8, from: []const u8, to_dir: []const u8, to: []const u8) !void {
    const src = try joinWide(a, from_dir, from);
    const dst = try joinWide(a, to_dir, to);
    if (w.MoveFileExW(src, dst, w.MOVEFILE_REPLACE_EXISTING) == 0) return lastError();
}

fn remove(a: std.mem.Allocator, dir: []const u8, name: []const u8) !void {
    const path = try joinWide(a, dir, name);
    if (w.DeleteFileW(path) == 0) return lastError();
}

fn lastError() error{ FileNotFound, AccessDenied, FileBusy, Unexpected } {
    return switch (w.GetLastError()) {
        2, 3 => error.FileNotFound,
        5 => error.AccessDenied,
        32 => error.FileBusy,
        else => error.Unexpected,
    };
}

fn joinWide(a: std.mem.Allocator, dir: []const u8, name: []const u8) ![:0]u16 {
    const path = try std.fmt.allocPrint(a, "{s}\\{s}", .{ dir, name });
    defer a.free(path);
    return std.unicode.wtf8ToWtf16LeAllocZ(a, path);
}

/// Deletes `X.old` wherever `X` is there too, so a file of someone else's
/// that happens to end in `.old` survives.
fn clearOld(gpa: std.mem.Allocator, io: Io, dir: Io.Dir) void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var found: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".old")) continue;
        found.append(a, a.dupe(u8, entry.name) catch return) catch return;
    }
    for (found.items) |name| {
        const kept = name[0 .. name.len - ".old".len];
        dir.access(io, kept, .{}) catch continue;
        dir.deleteFile(io, name) catch {};
    }
}

/// The folder this program runs from, as WTF-8.
fn programFolder(gpa: std.mem.Allocator) ![]u8 {
    var buf: [32768]u16 = undefined;
    const n = w.GetModuleFileNameW(null, &buf, buf.len);
    if (n == 0 or n >= buf.len) return error.NoProgramFolder;
    const cut = std.mem.lastIndexOfScalar(u16, buf[0..n], '\\') orelse return error.NoProgramFolder;
    return std.unicode.wtf16LeToWtf8Alloc(gpa, buf[0..cut]);
}

// ---- tests ----

const testing = std.testing;

const sample =
    \\{"tag_name":"v0.3.0","name":"ElephantSearch 0.3.0","assets":[
    \\{"name":"notes.txt","browser_download_url":"https://example.com/notes.txt"},
    \\{"name":"ElephantSearch-0.3.0-windows-x64.zip",
    \\ "browser_download_url":"https://github.com/Apostolique/ElephantSearch/releases/download/v0.3.0/ElephantSearch-0.3.0-windows-x64.zip",
    \\ "digest":"sha256:A24D48FDF8EB9E6D367A8847D9FB57B6798161B0A7F9154019D2BC34D2D535C0","size":1}]}
;

test "the release zip is picked out of GitHub's answer" {
    var release = try parse(testing.allocator, sample);
    defer release.deinit();
    try testing.expectEqualStrings("0.3.0", release.version);
    try testing.expect(std.mem.endsWith(u8, release.url, "/v0.3.0/ElephantSearch-0.3.0-windows-x64.zip"));
    try testing.expectEqualStrings("a24d48fdf8eb9e6d367a8847d9fb57b6798161b0a7f9154019d2bc34d2d535c0", &release.sha256);
}

test "the release outlives the answer it was read from" {
    const body = try testing.allocator.dupe(u8, sample);
    var release = try parse(testing.allocator, body);
    defer release.deinit();
    @memset(body, 'x');
    testing.allocator.free(body);
    try testing.expectEqualStrings("0.3.0", release.version);
}

test "a release without a checksum is refused" {
    const body =
        \\{"tag_name":"v0.3.0","assets":[{"name":"ElephantSearch-0.3.0-windows-x64.zip","browser_download_url":"https://x/y"}]}
    ;
    try testing.expectError(error.NoDigest, parse(testing.allocator, body));
}

test "a release without a zip for this version is refused" {
    const body =
        \\{"tag_name":"v0.3.0","assets":[{"name":"ElephantSearch-0.2.9-windows-x64.zip","browser_download_url":"https://x/y","digest":"sha256:00"}]}
    ;
    try testing.expectError(error.NoAsset, parse(testing.allocator, body));
}

test "versions compare as numbers, not as text" {
    try testing.expect(try isNewer("0.10.0", "0.9.1"));
    try testing.expect(!try isNewer("0.2.1", "0.2.1"));
    try testing.expect(!try isNewer("0.2.0", "0.2.1"));
    try testing.expectError(error.BadVersion, isNewer("latest", "0.2.1"));
}

test "a download address splits into host and path, and only over https" {
    const where = try split("https://github.com/a/b/c.zip");
    try testing.expectEqualStrings("github.com", where.host);
    try testing.expectEqualStrings("/a/b/c.zip", where.path);
    try testing.expectError(error.NoAsset, split("http://github.com/a"));
    try testing.expectError(error.NoAsset, split("https:///a"));
}

test "a swap moves the new files in and the old ones aside" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "app");
    try tmp.dir.createDirPath(io, "new");
    var app = try tmp.dir.openDir(io, "app", .{ .iterate = true });
    defer app.close(io);
    var new = try tmp.dir.openDir(io, "new", .{ .iterate = true });
    defer new.close(io);
    const app_path = try app.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(app_path);
    const new_path = try new.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(new_path);

    try app.writeFile(io, .{ .sub_path = "a.exe", .data = "old a" });
    try app.writeFile(io, .{ .sub_path = "mine.txt", .data = "untouched" });
    try new.writeFile(io, .{ .sub_path = "a.exe", .data = "new a" });
    try new.writeFile(io, .{ .sub_path = "b.exe", .data = "new b" });

    // Held the way Windows holds a program that is running: nobody else
    // gets to write to it while renaming it is allowed.
    const running_path = try joinWide(testing.allocator, app_path, "a.exe");
    defer testing.allocator.free(running_path);
    const running = w.CreateFileW(running_path, w.GENERIC_READ, w.FILE_SHARE_READ | w.FILE_SHARE_DELETE, null, w.OPEN_EXISTING, 0, null);
    try testing.expect(running != w.INVALID_HANDLE_VALUE);
    defer _ = w.CloseHandle(running);

    try swap(testing.allocator, io, new_path, app_path);

    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("new a", try app.readFile(io, "a.exe", &buf));
    try testing.expectEqualStrings("old a", try app.readFile(io, "a.exe.old", &buf));
    try testing.expectEqualStrings("new b", try app.readFile(io, "b.exe", &buf));
    try testing.expectEqualStrings("untouched", try app.readFile(io, "mine.txt", &buf));

    clearOld(testing.allocator, io, app);
    try testing.expectError(error.FileNotFound, app.access(io, "a.exe.old", .{}));
}

test "an .old file with nothing beside it is left alone" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "notes.old", .data = "keep" });
    clearOld(testing.allocator, io, tmp.dir);
    try tmp.dir.access(io, "notes.old", .{});
}
