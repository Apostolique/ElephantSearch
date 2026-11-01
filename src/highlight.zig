//! Which characters of a row the query actually matched, so the window can
//! draw those in bold and leave the rest alone.
//!
//! It works the alignment out again rather than remembering one. A fuzzy term
//! is scored on one particular run of characters -- the earliest end a greedy
//! forward pass reaches, with the start pulled as far right as it will go --
//! and carrying that through the search would cost every entry in the index a
//! few bytes to serve the twenty rows that end up on screen. Doing it here
//! costs the rows being drawn and nothing else.
//!
//! Which string to run it against is the search's own answer. A name-mode
//! search matched names, so only the name is marked and the directory beside
//! it stays plain, because it is not what the ranking looked at. A path-mode
//! search matched whole paths, so the path is marked in one go and the two
//! columns take their share of it, which is how a match that straddles the
//! last separator comes out bold on both sides of it.

const std = @import("std");
const score = @import("score.zig");
const search = @import("search.zig");
const toLower = @import("index.zig").toLower;

/// Longest subject worth marking. Windows paths run to 260 characters by
/// convention and the list cuts one short with an ellipsis long before this,
/// so anything past it could not be on screen to be bold.
pub const limit: usize = 2048;

/// One bit per byte of the subject: set means the query matched there.
pub const Marks = struct {
    words: [limit / 64]u64 = @splat(0),

    pub fn isSet(self: *const Marks, at: usize) bool {
        if (at >= limit) return false;
        return self.words[at >> 6] & bit(at) != 0;
    }

    fn set(self: *Marks, at: usize) void {
        if (at >= limit) return;
        self.words[at >> 6] |= bit(at);
    }

    fn setRange(self: *Marks, from: usize, to: usize) void {
        var at = from;
        while (at < to) : (at += 1) self.set(at);
    }

    fn bit(at: usize) u64 {
        return @as(u64, 1) << @truncate(at);
    }
};

/// A stretch of the subject that is either all matched or all not.
pub const Run = struct {
    from: u32,
    to: u32,
    matched: bool,
};

/// Marks the characters of `subject` the query matched.
///
/// `name_at` is where the file name starts inside it, which is zero when the
/// subject is the name itself. Wildcard terms are matched against the name
/// wherever it sits, the way the search matches them, so they need to be told.
pub fn mark(subject: []const u8, name_at: usize, q: search.Query, mode: search.Mode) Marks {
    var marks: Marks = .{};
    const hay = subject[0..@min(subject.len, limit)];
    if (name_at > hay.len) return marks;

    for (q.terms) |t| switch (t.kind) {
        .glob => {
            var hits: [search.max_glob_hits]u16 = undefined;
            const n = search.globHits(hay[name_at..], t.text, &hits);
            for (hits[0..n]) |at| marks.set(name_at + at);
        },
        .fuzzy => markFuzzy(&marks, hay, t.text, mode),
        .exact, .path => markLiteral(&marks, hay, t.text),
    };
    return marks;
}

/// The one alignment a fuzzy term was scored on, and no other. Bolding a
/// different run of the same letters would point at characters the ranking
/// never looked at, which is worse than pointing at nothing.
fn markFuzzy(marks: *Marks, hay: []const u8, pat: []const u8, mode: search.Mode) void {
    const forward = score.advance(.start, pat, hay, 0);
    if (!forward.complete(pat)) return;

    // Name mode scores without a span cap and path mode with the one a path
    // search uses, so the start lands where the score found it either way.
    const span = if (mode == .name) std.math.maxInt(usize) else search.maxSpan(pat.len);
    const start = score.alignStart(hay, pat, forward.end, span) orelse return;

    var pi: usize = 0;
    var at = start;
    while (at < forward.end and pi < pat.len) : (at += 1) {
        if (toLower(hay[at]) != pat[pi]) continue;
        marks.set(at);
        pi += 1;
    }
}

/// Every occurrence, rather than the one the score was taken from. Someone who
/// quoted a term meant all of them, and leaving the others plain reads as a
/// bug rather than as a ranking decision nobody asked to see.
fn markLiteral(marks: *Marks, hay: []const u8, pat: []const u8) void {
    if (pat.len == 0 or hay.len < pat.len) return;
    var at: usize = 0;
    outer: while (at + pat.len <= hay.len) : (at += 1) {
        for (pat, 0..) |c, j| {
            if (toLower(hay[at + j]) != c) continue :outer;
        }
        marks.setRange(at, at + pat.len);
    }
}

/// Splits `text` into runs, breaking wherever the marking changes and never
/// inside a character. `at` is where `text` starts inside the marked subject,
/// so a column showing part of a path can be handed the marks for the whole
/// of it. Returns how many runs it wrote.
///
/// Whatever is left when `out` fills up joins the run in progress rather than
/// being dropped: a query that alternates more often than that is not one
/// anyone is reading letter by letter, and a row with its tail missing is.
pub fn runs(text: []const u8, marks: *const Marks, at: usize, out: []Run) usize {
    if (out.len == 0 or text.len == 0) return 0;

    var count: usize = 0;
    var start: usize = 0;
    var state = marks.isSet(at);

    var i: usize = 0;
    while (i < text.len) {
        // A character at a time, because a mark lands on the first byte of one
        // and the rest of its bytes go wherever it goes.
        var next = i + 1;
        while (next < text.len and text[next] & 0xC0 == 0x80) next += 1;

        const here = marks.isSet(at + i);
        if (here != state and count + 1 < out.len) {
            out[count] = .{ .from = @intCast(start), .to = @intCast(i), .matched = state };
            count += 1;
            start = i;
            state = here;
        }
        i = next;
    }

    out[count] = .{ .from = @intCast(start), .to = @intCast(text.len), .matched = state };
    return count + 1;
}

/// Whether anything in `text` is marked at all. The plain case is worth
/// knowing about: a cell with nothing to bold goes through a single draw
/// call, ellipsis and all, instead of being laid out run by run.
pub fn anyIn(text: []const u8, marks: *const Marks, at: usize) bool {
    for (0..text.len) |i| {
        if (marks.isSet(at + i)) return true;
    }
    return false;
}

// ---- tests ----

const testing = std.testing;

/// Builds the marks a query would leave on one subject, the way the window
/// does, and returns them as a string with the matched characters uppercased.
fn shown(gpa: std.mem.Allocator, text: []const u8, query: []const u8, mode: search.Mode) ![]u8 {
    const q = try search.parseQuery(gpa, query, .{});
    defer search.freeQuery(gpa, q);

    const name_at = if (std.mem.lastIndexOfScalar(u8, text, '\\')) |at| at + 1 else 0;
    const marks = mark(text, if (mode == .name) 0 else name_at, q, mode);

    const out = try gpa.alloc(u8, text.len);
    for (text, out, 0..) |c, *o, i| {
        o.* = if (marks.isSet(i)) std.ascii.toUpper(c) else std.ascii.toLower(c);
    }
    return out;
}

test "a fuzzy term marks the letters it was scored on" {
    const got = try shown(testing.allocator, "main.zig", "mz", .name);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("Main.Zig", got);
}

test "a fuzzy term marks the tightest run, not the first letters that fit" {
    // The backward pass pulls the start right, so this lands on the extension
    // rather than on the `z` in the middle of the name.
    const got = try shown(testing.allocator, "zebra.zig", "zig", .name);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("zebra.ZIG", got);
}

test "a quoted term marks every occurrence" {
    const got = try shown(testing.allocator, "main_main.c", "\"main\"", .name);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("MAIN_MAIN.c", got);
}

test "a wildcard marks its literals and not what it stands for" {
    const got = try shown(testing.allocator, "report2024.txt", "*.txt", .name);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("report2024.TXT", got);
}

test "a wildcard in the middle marks both ends" {
    const got = try shown(testing.allocator, "backup_2024.tar", "b*.tar", .name);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("Backup_2024.TAR", got);
}

test "a missed term marks nothing" {
    const got = try shown(testing.allocator, "main.zig", "xyz", .name);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("main.zig", got);
}

test "every term gets marked" {
    const got = try shown(testing.allocator, "src_main.zig", "\"src\" \"zig\"", .name);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("SRC_main.ZIG", got);
}

test "a path term marks across the separator" {
    const got = try shown(testing.allocator, "c:\\work\\src\\main.zig", "src/main", .path);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("c:\\work\\SRC\\MAIN.zig", got);
}

test "path mode marks the directory a fuzzy term reached into" {
    const got = try shown(testing.allocator, "c:\\src\\main.zig", "srcmainzg", .path);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("c:\\SRC\\MAIN.ZiG", got);
}

test "name mode leaves the directory alone" {
    // The same subject the window hands a name-mode row: the name by itself.
    const got = try shown(testing.allocator, "main.zig", "main", .name);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("MAIN.zig", got);
}

test "runs alternate and cover the whole string" {
    const q = try search.parseQuery(testing.allocator, "\"ain\"", .{});
    defer search.freeQuery(testing.allocator, q);
    const text = "main.zig";
    const marks = mark(text, 0, q, .name);

    var out: [8]Run = undefined;
    const n = runs(text, &marks, 0, &out);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualStrings("m", text[out[0].from..out[0].to]);
    try testing.expect(!out[0].matched);
    try testing.expectEqualStrings("ain", text[out[1].from..out[1].to]);
    try testing.expect(out[1].matched);
    try testing.expectEqualStrings(".zig", text[out[2].from..out[2].to]);
    try testing.expect(!out[2].matched);
}

test "runs never split a character in half" {
    const q = try search.parseQuery(testing.allocator, "\"caf\"", .{});
    defer search.freeQuery(testing.allocator, q);
    // The last character is two bytes, and only its first can carry a mark.
    const text = "café.txt";
    const marks = mark(text, 0, q, .name);

    var out: [8]Run = undefined;
    const n = runs(text, &marks, 0, &out);
    var seen: usize = 0;
    for (out[0..n]) |r| {
        try testing.expectEqual(@as(u32, @intCast(seen)), r.from);
        // A run boundary is always a character boundary.
        try testing.expect(r.to == text.len or text[r.to] & 0xC0 != 0x80);
        seen = r.to;
    }
    try testing.expectEqual(text.len, seen);
}

test "runs hand a column the slice of the marks that belongs to it" {
    const q = try search.parseQuery(testing.allocator, "src\\main", .{});
    defer search.freeQuery(testing.allocator, q);
    const full = "c:\\src\\main.zig";
    const marks = mark(full, full.len - "main.zig".len, q, .path);

    // What the name column draws, marked from where the name sits.
    var out: [8]Run = undefined;
    const n = runs("main.zig", &marks, full.len - "main.zig".len, &out);
    try testing.expect(n >= 2);
    try testing.expect(out[0].matched);
    try testing.expectEqualStrings("main", "main.zig"[out[0].from..out[0].to]);
}

test "a run list too short keeps the tail" {
    const q = try search.parseQuery(testing.allocator, "\"a\"", .{});
    defer search.freeQuery(testing.allocator, q);
    const text = "abababab";
    const marks = mark(text, 0, q, .name);

    var out: [2]Run = undefined;
    const n = runs(text, &marks, 0, &out);
    try testing.expect(n <= out.len);
    try testing.expectEqual(@as(u32, @intCast(text.len)), out[n - 1].to);
}

test "glob hits agree with the matcher that let the row through" {
    const cases = [_]struct { name: []const u8, pat: []const u8 }{
        .{ .name = "main.zig", .pat = "*.zig" },
        .{ .name = "main.zig", .pat = "main*" },
        .{ .name = "a.b.c.zig", .pat = "*.*.zig" },
        .{ .name = "report.txt", .pat = "re?ort.txt" },
        .{ .name = "aaab", .pat = "*ab" },
        .{ .name = "xyz", .pat = "*.zig" },
    };
    for (cases) |c| {
        var hits: [search.max_glob_hits]u16 = undefined;
        const n = search.globHits(c.name, c.pat, &hits);
        if (!search.globMatch(c.name, c.pat)) {
            try testing.expectEqual(@as(usize, 0), n);
            continue;
        }
        // Every position it reports really does hold a literal of the pattern,
        // and they come back in order.
        var last: i32 = -1;
        for (hits[0..n]) |at| {
            try testing.expect(@as(i32, at) > last);
            last = at;
            try testing.expect(at < c.name.len);
        }
    }
}
