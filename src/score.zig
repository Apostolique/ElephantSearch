//! Fuzzy subsequence matching with a quality score, so `srcmainzg` finds
//! `src\main.zig` and the tightest match sorts first.
//!
//! The alignment is found the way fzf does it: one forward pass to locate the
//! earliest end that consumes the whole pattern, then a backward pass from
//! there to pull the start as far right as it goes. That keeps it linear in the
//! length of the name while still preferring compact matches over scattered
//! ones.
//!
//! The forward pass is split out as `Progress` so it can be stopped and
//! resumed. Matching a path means matching its parent's path and then the
//! name, and every file in a directory shares that parent, so the parent's
//! progress is computed once and each sibling only pays for its own name.
//!
//! `max_span` caps how far an alignment may stretch. A path long enough holds
//! nearly every letter, so without a cap even a typo matches something and the
//! results fill with noise. It also bounds the backward pass.

const std = @import("std");
const toLower = @import("index.zig").toLower;

const score_match: i32 = 16;
const bonus_boundary: i32 = 8;
const bonus_camel: i32 = 7;
const bonus_consecutive: i32 = 8;
/// The first pattern character carries more weight than the rest.
const bonus_first_multiplier: i32 = 2;
const penalty_gap_start: i32 = -3;
const penalty_gap_extend: i32 = -1;

const CharClass = enum { white, delimiter, lower, upper, digit };

fn classOf(c: u8) CharClass {
    return switch (c) {
        ' ', '\t' => .white,
        'a'...'z' => .lower,
        'A'...'Z' => .upper,
        '0'...'9' => .digit,
        else => .delimiter,
    };
}

/// How much of a word boundary the transition into `cur` is.
fn boundaryBonus(prev: CharClass, cur: CharClass) i32 {
    return switch (prev) {
        .white, .delimiter => switch (cur) {
            .white, .delimiter => 0,
            else => bonus_boundary,
        },
        .lower => switch (cur) {
            .upper => bonus_camel,
            .digit => bonus_camel,
            else => 0,
        },
        .digit => switch (cur) {
            .upper, .lower => bonus_camel,
            else => 0,
        },
        .upper => 0,
    };
}

/// A greedy forward match, part way through the pattern.
pub const Progress = struct {
    /// Pattern characters consumed so far.
    matched: usize = 0,
    /// Index just past the last consumed character. Only meaningful once the
    /// whole pattern has matched.
    end: usize = 0,

    pub const start: Progress = .{};

    pub fn complete(self: Progress, pat: []const u8) bool {
        return self.matched == pat.len;
    }
};

/// Continues a greedy match through `chunk`, whose first character sits at
/// `base` in the full string. `pat` must already be lowercase.
pub fn advance(p: Progress, pat: []const u8, chunk: []const u8, base: usize) Progress {
    var out = p;
    if (out.matched == pat.len) return out;
    for (chunk, 0..) |c, i| {
        if (toLower(c) == pat[out.matched]) {
            out.matched += 1;
            if (out.matched == pat.len) {
                out.end = base + i + 1;
                return out;
            }
        }
    }
    return out;
}

/// Latest start index such that `pat` still fits in `hay[start..end]`, giving
/// up once the window would exceed `max_span`.
///
/// Public because the score is not the only thing an alignment is good for:
/// the window bolds the characters it covers, and asking for them separately
/// would risk pointing at a different run of the same letters.
pub fn alignStart(hay: []const u8, pat: []const u8, end: usize, max_span: usize) ?usize {
    var pi = pat.len;
    var i = end;
    const floor = if (end > max_span) end - max_span else 0;
    while (i > floor) {
        i -= 1;
        if (toLower(hay[i]) == pat[pi - 1]) {
            pi -= 1;
            if (pi == 0) return i;
        }
    }
    return null;
}

/// Scores an alignment whose forward pass already ended at `end`. Returns null
/// when no alignment ending there fits inside `max_span`.
pub fn scoreAt(hay: []const u8, pat: []const u8, end: usize, max_span: usize) ?i32 {
    const start = alignStart(hay, pat, end, max_span) orelse return null;

    var total: i32 = 0;
    var pi: usize = 0;
    var in_gap = false;
    var consecutive: i32 = 0;
    var first_bonus: i32 = 0;

    var i = start;
    while (i < end) : (i += 1) {
        const c = hay[i];
        if (pi < pat.len and toLower(c) == pat[pi]) {
            total += score_match;

            const prev: CharClass = if (i == 0) .delimiter else classOf(hay[i - 1]);
            var bonus = boundaryBonus(prev, classOf(c));
            if (consecutive == 0) {
                first_bonus = bonus;
            } else {
                // Inside a run, keep the strongest boundary the run started on.
                if (bonus >= bonus_boundary and bonus > first_bonus) first_bonus = bonus;
                bonus = @max(@max(bonus, first_bonus), bonus_consecutive);
            }
            total += if (pi == 0) bonus * bonus_first_multiplier else bonus;

            in_gap = false;
            consecutive += 1;
            pi += 1;
        } else {
            total += if (in_gap) penalty_gap_extend else penalty_gap_start;
            in_gap = true;
            consecutive = 0;
            first_bonus = 0;
        }
    }

    // Between two equally tight matches, the shorter subject is the better hit.
    total -= @intCast(@min(hay.len, 255) / 8);
    return total;
}

/// Score of `pat` against `hay`, or null when `pat` is not a subsequence.
/// `pat` must already be lowercase and non-empty.
pub fn fuzzy(hay: []const u8, pat: []const u8) ?i32 {
    return fuzzyWithin(hay, pat, std.math.maxInt(usize));
}

/// Same, rejecting any alignment that covers more than `max_span` characters.
pub fn fuzzyWithin(hay: []const u8, pat: []const u8, max_span: usize) ?i32 {
    if (pat.len > hay.len) return null;
    const p = advance(.start, pat, hay, 0);
    if (!p.complete(pat)) return null;
    return scoreAt(hay, pat, p.end, max_span);
}

/// Last position at which `pat` occurs contiguously in `hay`, ignoring case.
/// `pat` must already be lowercase.
pub fn lastIndexIgnoreCase(hay: []const u8, pat: []const u8) ?usize {
    if (pat.len == 0 or hay.len < pat.len) return null;
    var i = hay.len - pat.len + 1;
    outer: while (i > 0) {
        i -= 1;
        for (pat, 0..) |c, j| {
            if (toLower(hay[i + j]) != c) continue :outer;
        }
        return i;
    }
    return null;
}

test "contiguous beats scattered" {
    const tight = fuzzy("main.zig", "main").?;
    const loose = fuzzy("mxaxixn.zig", "main").?;
    try std.testing.expect(tight > loose);
}

test "word boundary beats mid-word" {
    const boundary = fuzzy("my_config.txt", "config").?;
    const midword = fuzzy("unconfigured.txt", "config").?;
    try std.testing.expect(boundary > midword);
}

test "shorter name wins on equal alignment" {
    const short = fuzzy("app.zig", "app").?;
    const long = fuzzy("app_with_a_long_tail.zig", "app").?;
    try std.testing.expect(short > long);
}

test "camel case boundaries" {
    const camel = fuzzy("SearchProvider.cs", "sp").?;
    const buried = fuzzy("thespoon.cs", "sp").?;
    try std.testing.expect(camel > buried);
}

test "non subsequence returns null" {
    try std.testing.expect(fuzzy("main.zig", "xyz") == null);
    try std.testing.expect(fuzzy("main.zig", "gnz") == null);
    try std.testing.expect(fuzzy("ab", "abc") == null);
}

test "order matters" {
    try std.testing.expect(fuzzy("main.zig", "mz") != null);
    try std.testing.expect(fuzzy("main.zig", "zm") == null);
}

test "case insensitive" {
    try std.testing.expect(fuzzy("README.MD", "readme") != null);
    try std.testing.expect(fuzzy("readme.md", "README") == null); // pattern must arrive lowercased
}

test "a span cap rejects a match smeared across a long path" {
    const long = "c:\\users\\user\\documents\\github\\notes\\readme.md";
    try std.testing.expect(fuzzy(long, "zzz") == null);
    try std.testing.expect(fuzzy(long, "cudgm") != null);
    try std.testing.expect(fuzzyWithin(long, "cudgm", 12) == null);
    try std.testing.expect(fuzzyWithin(long, "readme", 12) != null);
}

test "a cap does not change the score of what it lets through" {
    const capped = fuzzyWithin("src\\main.zig", "main", 16).?;
    const uncapped = fuzzy("src\\main.zig", "main").?;
    try std.testing.expectEqual(uncapped, capped);
}

test "resuming through chunks matches scanning the whole string" {
    const full = "c:\\users\\user\\src\\main.zig";
    const pat = "srcmainzg";

    const whole = advance(.start, pat, full, 0);
    try std.testing.expect(whole.complete(pat));

    // Split the same string anywhere and the greedy match lands identically.
    for (1..full.len) |cut| {
        const first = advance(.start, pat, full[0..cut], 0);
        const second = advance(first, pat, full[cut..], cut);
        try std.testing.expect(second.complete(pat));
        try std.testing.expectEqual(whole.end, second.end);
    }
}

test "a resumed match scores the same as a whole one" {
    const full = "c:\\users\\user\\src\\main.zig";
    const pat = "srcmainzg";
    const cut = std.mem.lastIndexOfScalar(u8, full, '\\').?;

    const resumed = advance(advance(.start, pat, full[0..cut], 0), pat, full[cut..], cut);
    const from_parts = scoreAt(full, pat, resumed.end, 64).?;
    const in_one_go = fuzzyWithin(full, pat, 64).?;
    try std.testing.expectEqual(in_one_go, from_parts);
}

test "last occurrence wins" {
    try std.testing.expectEqual(@as(?usize, 13), lastIndexIgnoreCase("src\\main\\src\\main.zig", "main"));
    try std.testing.expectEqual(@as(?usize, 0), lastIndexIgnoreCase("MAIN.zig", "main"));
    try std.testing.expectEqual(@as(?usize, null), lastIndexIgnoreCase("main.zig", "nope"));
}
