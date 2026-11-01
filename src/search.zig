//! Query matching over the flat index.
//!
//! Matching runs in one of two modes. Name mode compares against file names
//! only, which is cheap because a name is a slice of the blob and a 32-bit
//! character bloom rejects most entries with one AND. Path mode rebuilds each
//! full path and compares against that, which costs a lot more but is the only
//! way `srcmainzg` can find `src\main.zig`. A query starts in name mode and
//! falls back to path mode when the names alone barely answer it.
//!
//! On top of that, the scan is split across cores, a query that extends the
//! previous one only rescans the previous result set, and ranking uses a
//! bounded top-k heap so a query matching half the drive still only sorts the
//! rows that get shown.

const std = @import("std");
const w = @import("win32.zig");
const idx = @import("index.zig");
const score = @import("score.zig");
const Index = idx.Index;
const toLower = idx.toLower;
const compareNames = idx.compareNames;

/// A name-mode search returning fewer than this many hits is treated as a miss,
/// and the query is retried against full paths.
const path_fallback_below: usize = 20;

/// How far a fuzzy alignment may stretch inside a path, as a multiple of the
/// term length plus slack. A path long enough holds nearly every letter, so
/// without this even a typo matches something and the results fill with noise.
const span_slope: usize = 4;
const span_slack: usize = 16;

pub fn maxSpan(term_len: usize) usize {
    return term_len * span_slope + span_slack;
}

/// Narrowing over a candidate set this large costs more than a linear scan,
/// because every lookup jumps around the entry arrays instead of streaming.
fn worthNarrowing(candidates: usize, entries: u32) bool {
    return candidates <= entries / 4;
}

pub const Match = struct {
    entry: u32,
    score: i32,
};

/// What the list is ordered by. `relevance` is how well the query matched,
/// which is the only one of these a search produces on its own. The rest are
/// columns, and cost a comparison against the index for every match.
pub const SortBy = enum { relevance, name, path, size, modified };

pub const Order = struct {
    by: SortBy = .relevance,
    /// Reverses the column orders. Relevance ignores it, because a list of the
    /// worst matches first is not something anyone asks for.
    descending: bool = false,
};

/// Puts two matches in order. Ranking by a column rather than by score costs
/// the same single pass, because the bounded heap underneath only needs a
/// comparison and does not care what it compares.
pub const Ranking = struct {
    index: *const Index,
    order: Order = .{},

    /// Whether `a` belongs above `b`. Equal rows fall back to the entry
    /// number, which makes the order total: without a tie break the heap and
    /// the sort after it can disagree about two equal rows, and the list
    /// reshuffles under whoever scrolls it.
    pub fn better(self: Ranking, a: Match, b: Match) bool {
        return switch (self.compare(a, b)) {
            .lt => true,
            .gt => false,
            .eq => a.entry < b.entry,
        };
    }

    /// The shape `std.sort` wants, which is the same question.
    pub fn lessThan(self: Ranking, a: Match, b: Match) bool {
        return self.better(a, b);
    }

    /// `.lt` when `a` belongs above `b`, before the tie break.
    fn compare(self: Ranking, a: Match, b: Match) std.math.Order {
        // Backwards on purpose: a high score is a good match, and good matches
        // belong at the top. It leaves before the flag below because reversing
        // it would put the worst first.
        if (self.order.by == .relevance) return std.math.order(b.score, a.score);

        const s = self.index.entries.slice();
        // Folders above files, and still above once the order is turned
        // around, the way Explorer keeps them. Only sorting on a column does
        // this: ranking by how well a query matched is answering a different
        // question, and a folder that matches badly has not earned the top.
        const dirs = s.items(.is_dir);
        if (dirs[a.entry] != dirs[b.entry]) return if (dirs[a.entry]) .lt else .gt;

        const ord: std.math.Order = switch (self.order.by) {
            .relevance => unreachable,
            .name => compareNames(self.index.nameOf(a.entry), self.index.nameOf(b.entry)),
            .path => self.comparePaths(a.entry, b.entry),
            .size => std.math.order(s.items(.size)[a.entry], s.items(.size)[b.entry]),
            .modified => std.math.order(s.items(.modified)[a.entry], s.items(.modified)[b.entry]),
        };
        return if (self.order.descending) ord.invert() else ord;
    }

    /// Orders two entries by their full paths without building either one.
    ///
    /// The layout pass walks the tree depth first with each directory's
    /// children in name order, so everything it covers is already in path
    /// order and the entry number answers this outright. Only the tail the
    /// change journal appended since sits outside that, and those walk the two
    /// parent chains and compare them a directory name at a time.
    fn comparePaths(self: Ranking, a: u32, b: u32) std.math.Order {
        if (a == b) return .eq;
        if (a < self.index.ordered and b < self.index.ordered) return std.math.order(a, b);

        const parents = self.index.entries.slice().items(.parent);

        var up_a: [idx.max_depth]u32 = undefined;
        var up_b: [idx.max_depth]u32 = undefined;
        const depth_a = ancestry(parents, a, &up_a);
        const depth_b = ancestry(parents, b, &up_b);

        var i: usize = 0;
        while (i < depth_a and i < depth_b) : (i += 1) {
            // Both chains are deepest first, so this counts down from the root.
            const at_a = up_a[depth_a - 1 - i];
            const at_b = up_b[depth_b - 1 - i];
            if (at_a == at_b) continue;
            const ord = compareNames(self.index.nameOf(at_a), self.index.nameOf(at_b));
            if (ord != .eq) return ord;
        }
        // One is the other with more directories on the end, so it sorts after.
        return std.math.order(depth_a, depth_b);
    }
};

/// Fills `into` with an entry and its ancestors, deepest first, and says how
/// many that came to. A root is its own parent, which is where it stops.
fn ancestry(parents: []const u32, entry: u32, into: *[idx.max_depth]u32) usize {
    var depth: usize = 0;
    var cur = entry;
    while (depth < idx.max_depth) {
        into[depth] = cur;
        depth += 1;
        const p = parents[cur];
        if (p == cur) break;
        cur = p;
    }
    return depth;
}

pub const Mode = enum { name, path };

pub const Kind = enum {
    /// Characters in order, gaps allowed, scored on how tight the match is.
    fuzzy,
    /// Contiguous, case insensitive.
    exact,
    /// Anchored at both ends, with * and ? wildcards. Always on the name, since
    /// anchoring a pattern to a string starting with `C:\` is never useful.
    glob,
    /// Contiguous, and always against the full path.
    path,
};

pub const Term = struct {
    /// Already lowercased.
    text: []const u8,
    bloom: u32,
    kind: Kind,
};

pub const Query = struct {
    terms: []const Term,
    /// Characters every name-matching term needs. Only valid in name mode.
    name_bloom: u32,
    /// Characters every term needs, name-matching or not. A path bloom is a
    /// superset of a name bloom, so this filters path mode.
    path_bloom: u32,
    has_path_terms: bool,
    /// Whether anything here could match more of the path than of the name.
    can_use_paths: bool,

    pub fn isEmpty(self: Query) bool {
        return self.terms.len == 0;
    }
};

pub const ParseOptions = struct {
    /// What a plain term means. Quoting a term always forces `.exact`.
    default_kind: Kind = .fuzzy,
};

pub fn parseQuery(gpa: std.mem.Allocator, text: []const u8, opts: ParseOptions) !Query {
    var terms: std.ArrayList(Term) = .empty;
    errdefer {
        for (terms.items) |t| gpa.free(t.text);
        terms.deinit(gpa);
    }

    var name_bloom: u32 = 0;
    var path_bloom: u32 = 0;
    var has_path_terms = false;
    var can_use_paths = false;
    var it = std.mem.tokenizeScalar(u8, text, ' ');
    while (it.next()) |token| {
        var raw = token;
        var quoted = false;
        if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"') {
            raw = raw[1 .. raw.len - 1];
            quoted = true;
        }
        if (raw.len == 0) continue;

        const lowered = try gpa.alloc(u8, raw.len);
        errdefer gpa.free(lowered);
        for (raw, lowered) |c, *o| o.* = toLower(c);

        var has_wildcard = false;
        var has_sep = false;
        for (lowered) |c| switch (c) {
            '*', '?' => has_wildcard = true,
            '\\', '/' => has_sep = true,
            else => {},
        };
        if (has_sep) {
            for (lowered) |*c| {
                if (c.* == '/') c.* = '\\';
            }
        }

        const kind: Kind = if (has_sep)
            .path
        else if (has_wildcard)
            .glob
        else if (quoted)
            .exact
        else
            opts.default_kind;

        // Every literal character of a term has to be present in whatever it
        // matches against, wildcards included once they are stripped out.
        const term_bloom = literalBloom(lowered);
        path_bloom |= term_bloom;
        switch (kind) {
            .path => has_path_terms = true,
            .fuzzy, .exact => {
                can_use_paths = true;
                name_bloom |= term_bloom;
            },
            .glob => name_bloom |= term_bloom,
        }

        try terms.append(gpa, .{ .text = lowered, .bloom = term_bloom, .kind = kind });
    }

    return .{
        .terms = try terms.toOwnedSlice(gpa),
        .name_bloom = name_bloom,
        .path_bloom = path_bloom,
        .has_path_terms = has_path_terms,
        .can_use_paths = can_use_paths,
    };
}

/// Character set of a term, ignoring wildcards and separators. A `?` stands for
/// any single character and a `*` for any run, so neither contributes anything.
/// Separators drop out because a path bloom unions the blooms of ancestor
/// names, and a name never holds one.
fn literalBloom(term: []const u8) u32 {
    var mask: u32 = 0;
    for (term) |c| {
        switch (c) {
            '*', '?', '\\', '/' => continue,
            else => mask |= @as(u32, 1) << @truncate(c & 31),
        }
    }
    return mask;
}

pub fn freeQuery(gpa: std.mem.Allocator, q: Query) void {
    for (q.terms) |t| gpa.free(t.text);
    gpa.free(q.terms);
}

/// `needle` is already lowercased.
pub fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (hay.len < needle.len) return false;
    const first = needle[0];
    const last = hay.len - needle.len;
    var i: usize = 0;
    outer: while (i <= last) : (i += 1) {
        if (toLower(hay[i]) != first) continue;
        for (needle[1..], 1..) |c, j| {
            if (toLower(hay[i + j]) != c) continue :outer;
        }
        return true;
    }
    return false;
}

/// `pat` is lowercased and anchored at both ends, with `*` and `?` wildcards.
pub fn globMatch(name: []const u8, pat: []const u8) bool {
    var s: usize = 0;
    var p: usize = 0;
    var star: ?usize = null;
    var retry: usize = 0;
    while (s < name.len) {
        if (p < pat.len and (pat[p] == '?' or toLower(name[s]) == pat[p])) {
            s += 1;
            p += 1;
        } else if (p < pat.len and pat[p] == '*') {
            star = p;
            retry = s;
            p += 1;
        } else if (star) |sp| {
            retry += 1;
            s = retry;
            p = sp + 1;
        } else return false;
    }
    while (p < pat.len and pat[p] == '*') p += 1;
    return p == pat.len;
}

/// How many of a pattern's literal characters get their positions recorded.
/// Past this the match still holds and only the tail of it goes unbolded,
/// which is not something anyone is reading a 64 character glob for.
pub const max_glob_hits: usize = 64;

/// Where a glob's literal characters landed in `name`, for the window to draw
/// those in bold. Returns how many it wrote, and zero when the pattern misses.
///
/// A separate walk rather than an out parameter on `globMatch`: that one runs
/// once per entry across the whole index, and the couple of dozen rows that
/// get drawn are the only ones anybody needs positions for. The two have to
/// agree, so they sit next to each other.
pub fn globHits(name: []const u8, pat: []const u8, into: *[max_glob_hits]u16) usize {
    var found: usize = 0;
    var s: usize = 0;
    var p: usize = 0;
    var star: ?usize = null;
    var retry: usize = 0;
    while (s < name.len) {
        if (p < pat.len and (pat[p] == '?' or toLower(name[s]) == pat[p])) {
            // A `?` stands for any character, so it points at nothing the
            // person searching typed and nothing worth pointing at.
            if (pat[p] != '?' and found < into.len) {
                into[found] = @truncate(s);
                found += 1;
            }
            s += 1;
            p += 1;
        } else if (p < pat.len and pat[p] == '*') {
            star = p;
            retry = s;
            p += 1;
        } else if (star) |sp| {
            retry += 1;
            s = retry;
            p = sp + 1;
            // Whatever matched after the star is about to be looked for again
            // further along, so it is no longer where it was found. Anything
            // from before the star sits below `retry` and stays.
            while (found > 0 and into[found - 1] >= retry) found -= 1;
        } else return 0;
    }
    while (p < pat.len and pat[p] == '*') p += 1;
    return if (p == pat.len) found else 0;
}

/// Combined score against the name alone, or null when a term misses. A query
/// holding a path term can never be answered here.
fn scoreName(name: []const u8, name_bloom: u32, q: Query) ?i32 {
    var total: i32 = 0;
    for (q.terms) |t| {
        switch (t.kind) {
            .path => return null,
            .glob => if (!globMatch(name, t.text)) return null,
            .exact => {
                if (t.bloom & name_bloom != t.bloom) return null;
                if (!containsIgnoreCase(name, t.text)) return null;
                total += score.fuzzy(name, t.text) orelse return null;
            },
            .fuzzy => {
                if (t.bloom & name_bloom != t.bloom) return null;
                total += score.fuzzy(name, t.text) orelse return null;
            },
        }
    }
    return total;
}

/// Combined score against the full path. Globs stay on the name, everything
/// else matches the whole thing.
fn scorePath(full: []const u8, name: []const u8, q: Query) ?i32 {
    var total: i32 = 0;
    for (q.terms) |t| {
        switch (t.kind) {
            .glob => if (!globMatch(name, t.text)) return null,
            .exact, .path => {
                // The last occurrence, matching what the resumed path scores.
                const at = score.lastIndexIgnoreCase(full, t.text) orelse return null;
                total += score.scoreAt(full, t.text, at + t.text.len, maxSpan(t.text.len)) orelse return null;
            },
            .fuzzy => total += score.fuzzyWithin(full, t.text, maxSpan(t.text.len)) orelse return null,
        }
    }
    return total;
}

const Shard = struct {
    index: *const Index,
    query: Query,
    gpa: std.mem.Allocator,
    mode: Mode,
    /// Either a range of entry indices, or a slice of candidates to narrow.
    from: u32 = 0,
    to: u32 = 0,
    candidates: ?[]const Match = null,
    out: std.ArrayList(Match) = .empty,
    err: ?anyerror = null,

    fn run(self: *Shard) void {
        self.exec() catch |e| {
            self.err = e;
        };
    }

    fn exec(self: *Shard) !void {
        return switch (self.mode) {
            .name => self.execNames(),
            .path => self.execPaths(),
        };
    }

    fn execNames(self: *Shard) !void {
        const slice = self.index.entries.slice();
        const blooms = slice.items(.bloom);
        const offs = slice.items(.name_off);
        const lens = slice.items(.name_len);
        const names = self.index.names.items;
        const q = self.query;

        if (self.candidates) |cands| {
            for (cands) |m| {
                const i = m.entry;
                if (blooms[i] & q.name_bloom != q.name_bloom) continue;
                const s = scoreName(names[offs[i]..][0..lens[i]], blooms[i], q) orelse continue;
                try self.out.append(self.gpa, .{ .entry = i, .score = s });
            }
            return;
        }

        var i = self.from;
        while (i < self.to) : (i += 1) {
            if (blooms[i] & q.name_bloom != q.name_bloom) continue;
            if (lens[i] == 0) continue;
            const s = scoreName(names[offs[i]..][0..lens[i]], blooms[i], q) orelse continue;
            try self.out.append(self.gpa, .{ .entry = i, .score = s });
        }
    }

    /// Path mode rebuilds and rematches a full path per candidate, which is the
    /// expensive part. Three things hold the cost down: the path bloom rejects
    /// entries before any of it happens, the previous entry's directory prefix
    /// is kept so a sibling costs one memcpy of its name, and the match state
    /// that prefix produced is kept too, so a sibling only rematches its name
    /// instead of the whole path.
    fn execPaths(self: *Shard) !void {
        // The walk needs entries in storage order, which a narrowed candidate
        // list is not, and it only carries state for so many terms.
        if (self.candidates != null or self.query.terms.len > max_cached_terms) {
            return self.execPathsScanning();
        }
        return self.execPathsWalking();
    }

    /// Walks the entries as the tree they are laid out as, carrying one frame
    /// per directory currently open. Each entry advances the match state of its
    /// parent through its own name, so nothing rescans a path prefix and no
    /// parent chain is ever walked.
    fn execPathsWalking(self: *Shard) !void {
        const slice = self.index.entries.slice();
        const path_blooms = slice.items(.path_bloom);
        const parents = slice.items(.parent);
        const offs = slice.items(.name_off);
        const lens = slice.items(.name_len);
        const dirs = slice.items(.is_dir);
        const names = self.index.names.items;
        const q = self.query;

        var buf: [32 * 1024]u8 = undefined;
        const frames = try self.gpa.alloc(Frame, idx.max_depth + 1);
        defer self.gpa.free(frames);
        const states = try self.gpa.alloc(TermState, (idx.max_depth + 2) * max_cached_terms);
        defer self.gpa.free(states);
        var scratch: [max_cached_terms]TermState = undefined;

        var walk: PathWalk = .{
            .index = self.index,
            .query = q,
            .buf = &buf,
            .frames = frames,
            .states = states,
        };
        if (parents[self.from] != self.from) walk.openTo(parents[self.from]);

        var i = self.from;
        while (i < self.to) : (i += 1) {
            const parent = parents[i];
            if (parent == i) {
                walk.top = 0;
            } else {
                while (walk.top > 0 and frames[walk.top - 1].id != parent) walk.top -= 1;
                // Entries are laid out depth first, so the parent is normally
                // still open. Anything added since then needs a fresh stack.
                if (walk.top == 0) walk.openTo(parent);
            }

            const base: usize = if (walk.top == 0) 0 else frames[walk.top - 1].path_len;
            const is_dir = dirs[i];

            // A directory has to be walked into even when it cannot match,
            // because whatever sits under it still might.
            const wanted = lens[i] != 0 and path_blooms[i] & q.path_bloom == q.path_bloom;
            if (!is_dir and !wanted) continue;

            const name = names[offs[i]..][0..lens[i]];
            const len = appendName(&buf, base, name);
            const keeps_state = is_dir and walk.top < idx.max_depth;
            const out = if (keeps_state) walk.stateAt(walk.top) else scratch[0..q.terms.len];
            const parent_state = walk.parentState();

            const s = stepTerms(buf[0..len], name, base, q, parent_state, out, keeps_state);

            if (keeps_state) {
                frames[walk.top] = .{ .id = i, .path_len = @intCast(len) };
                walk.top += 1;
            }

            if (wanted) {
                if (s) |value| try self.out.append(self.gpa, .{ .entry = i, .score = value });
            }
        }
    }

    fn execPathsScanning(self: *Shard) !void {
        const slice = self.index.entries.slice();
        const path_blooms = slice.items(.path_bloom);
        const parents = slice.items(.parent);
        const offs = slice.items(.name_off);
        const lens = slice.items(.name_len);
        const names = self.index.names.items;
        const q = self.query;

        var buf: [32 * 1024]u8 = undefined;
        var stack: [idx.max_depth]u32 = undefined;
        var cached_parent: u32 = std.math.maxInt(u32);
        var prefix_len: usize = 0;
        var state: [max_cached_terms]TermState = undefined;
        const cacheable = q.terms.len <= max_cached_terms;

        const count: usize = if (self.candidates) |c| c.len else self.to - self.from;
        var pos: usize = 0;
        while (pos < count) : (pos += 1) {
            const i: u32 = if (self.candidates) |c| c[pos].entry else self.from + @as(u32, @intCast(pos));
            if (path_blooms[i] & q.path_bloom != q.path_bloom) continue;
            if (lens[i] == 0) continue;

            const name = names[offs[i]..][0..lens[i]];
            const parent = parents[i];

            // A volume root has no parent path to inherit.
            if (parent == i or !cacheable) {
                const len = self.index.pathInto(i, &buf, &stack);
                const s = scorePath(buf[0..len], name, q) orelse continue;
                try self.out.append(self.gpa, .{ .entry = i, .score = s });
                continue;
            }

            if (parent != cached_parent) {
                prefix_len = self.index.pathInto(parent, &buf, &stack);
                primeTerms(q, buf[0..prefix_len], state[0..q.terms.len]);
                cached_parent = parent;
            }

            var len = prefix_len;
            if (len < buf.len) {
                buf[len] = '\\';
                len += 1;
            }
            const n = @min(name.len, buf.len - len);
            @memcpy(buf[len..][0..n], name[0..n]);
            len += n;

            const s = scoreResumed(buf[0..len], name, prefix_len, q, state[0..q.terms.len]) orelse continue;
            try self.out.append(self.gpa, .{ .entry = i, .score = s });
        }
    }
};

/// How many terms the per-directory match cache holds. A longer query falls
/// back to matching every path from scratch.
const max_cached_terms = 8;

/// A directory the walk is currently inside.
const Frame = struct {
    id: u32,
    /// Length of this directory's path in the shared buffer.
    path_len: u32,
};

/// The stack of directories a path scan is currently inside, along with how far
/// each one carried the query.
const PathWalk = struct {
    index: *const Index,
    query: Query,
    buf: []u8,
    frames: []Frame,
    states: []TermState,
    top: usize = 0,

    fn stateAt(self: *PathWalk, k: usize) []TermState {
        return self.states[k * max_cached_terms ..][0..self.query.terms.len];
    }

    fn parentState(self: *PathWalk) ?[]const TermState {
        return if (self.top == 0) null else self.stateAt(self.top - 1);
    }

    /// Rebuilds the stack from the root down, leaving `dir` on top.
    fn openTo(self: *PathWalk, dir: u32) void {
        const parents = self.index.entries.slice().items(.parent);

        var chain: [idx.max_depth]u32 = undefined;
        var depth: usize = 0;
        var cur = dir;
        while (depth < idx.max_depth) {
            chain[depth] = cur;
            depth += 1;
            const p = parents[cur];
            if (p == cur) break;
            cur = p;
        }

        self.top = 0;
        var len: usize = 0;
        while (depth > 0) {
            depth -= 1;
            const id = chain[depth];
            const name = self.index.nameOf(id);
            const base = len;
            len = appendName(self.buf, len, name);
            _ = stepTerms(
                self.buf[0..len],
                name,
                base,
                self.query,
                self.parentState(),
                self.stateAt(self.top),
                true,
            );
            self.frames[self.top] = .{ .id = id, .path_len = @intCast(len) };
            self.top += 1;
        }
    }
};

/// Appends `SEPname` to `buf` at `len` and returns the new length.
fn appendName(buf: []u8, len: usize, name: []const u8) usize {
    var out = len;
    if (out > 0 and out < buf.len) {
        buf[out] = '\\';
        out += 1;
    }
    const n = @min(name.len, buf.len - out);
    @memcpy(buf[out..][0..n], name[0..n]);
    return out + n;
}

/// Advances every term through `full[base..]` and scores the result. `out` is
/// filled with the state a child would resume from, which is why a failing term
/// does not stop the others unless `need_state` is false.
fn stepTerms(
    full: []const u8,
    name: []const u8,
    base: usize,
    q: Query,
    parent: ?[]const TermState,
    out: []TermState,
    need_state: bool,
) ?i32 {
    var total: i32 = 0;
    var matched = true;
    for (q.terms, out, 0..) |t, *o, k| {
        const prev: TermState = if (parent) |ps| ps[k] else .{};
        switch (t.kind) {
            .glob => {
                o.* = prev;
                if (!globMatch(name, t.text)) matched = false;
            },
            .fuzzy => {
                const p = score.advance(prev.progress, t.text, full[base..], base);
                o.* = .{ .progress = p };
                if (p.complete(t.text)) {
                    if (score.scoreAt(full, t.text, p.end, maxSpan(t.text.len))) |v| {
                        total += v;
                    } else matched = false;
                } else matched = false;
            },
            .exact, .path => {
                const from = base -| (t.text.len - 1);
                const at = if (score.lastIndexIgnoreCase(full[from..], t.text)) |x|
                    from + x
                else
                    prev.found_at;
                o.* = .{ .found_at = at };
                if (at) |pos| {
                    if (score.scoreAt(full, t.text, pos + t.text.len, maxSpan(t.text.len))) |v| {
                        total += v;
                    } else matched = false;
                } else matched = false;
            },
        }
        if (!matched and !need_state) return null;
    }
    return if (matched) total else null;
}

/// How far a directory's own path carried each term of the query.
const TermState = struct {
    /// Fuzzy terms: the greedy forward match, part way through.
    progress: score.Progress = .start,
    /// Contiguous terms: last offset in the directory path holding the term.
    found_at: ?usize = null,
};

/// Matches every term against a directory path, so its files can pick up where
/// it left off.
fn primeTerms(q: Query, prefix: []const u8, state: []TermState) void {
    for (q.terms, state) |t, *st| {
        st.* = switch (t.kind) {
            .fuzzy => .{ .progress = score.advance(.start, t.text, prefix, 0) },
            .exact, .path => .{ .found_at = score.lastIndexIgnoreCase(prefix, t.text) },
            .glob => .{},
        };
    }
}

/// Same result as `scorePath`, reached by resuming each term from what the
/// parent directory already matched.
fn scoreResumed(
    full: []const u8,
    name: []const u8,
    prefix_len: usize,
    q: Query,
    state: []const TermState,
) ?i32 {
    const tail = full[prefix_len..];
    var total: i32 = 0;
    for (q.terms, state) |t, st| {
        switch (t.kind) {
            .glob => if (!globMatch(name, t.text)) return null,
            .fuzzy => {
                const p = score.advance(st.progress, t.text, tail, prefix_len);
                if (!p.complete(t.text)) return null;
                total += score.scoreAt(full, t.text, p.end, maxSpan(t.text.len)) orelse return null;
            },
            .exact, .path => {
                // A contiguous match can straddle the boundary, so look again
                // from just far enough back to catch one that does.
                const from = prefix_len -| (t.text.len - 1);
                const at = if (score.lastIndexIgnoreCase(full[from..], t.text)) |k|
                    from + k
                else
                    st.found_at orelse return null;
                total += score.scoreAt(full, t.text, at + t.text.len, maxSpan(t.text.len)) orelse return null;
            },
        }
    }
    return total;
}

pub const Searcher = struct {
    gpa: std.mem.Allocator,
    index: *Index,
    threads: usize,
    default_kind: Kind = .fuzzy,
    last_query: std.ArrayList(u8) = .empty,
    last_results: std.ArrayList(Match) = .empty,
    ranked: std.ArrayList(Match) = .empty,
    has_last: bool = false,
    /// Entry count the cached results were produced against.
    last_count: u32 = 0,
    /// Mode the cached results were produced in. Narrowing across modes would
    /// be wrong, since path results are not a subset of name results.
    last_mode: Mode = .name,
    /// Nanoseconds the most recent search took, ranking included.
    last_nanos: u64 = 0,
    /// Whether the most recent search reused the cached result set.
    narrowed: bool = false,
    /// Mode the most recent search settled on.
    mode: Mode = .name,
    /// Restricts every search to one directory's run of entries. Null searches
    /// everything. Set it through `setScope`, which drops the cached results.
    scope: ?idx.Range = null,
    /// What the ranked list is sorted by. Outlives a query, the way a column
    /// clicked in Explorer stays clicked. Set it through `setOrder`.
    order: Order = .{},

    /// The stretch of entries searches are allowed to touch.
    fn span(self: *const Searcher) idx.Range {
        return self.scope orelse .{ .from = 0, .to = self.index.count() };
    }

    pub fn setScope(self: *Searcher, scope: ?idx.Range) void {
        self.scope = scope;
        self.invalidate();
    }

    pub fn init(gpa: std.mem.Allocator, index: *Index) Searcher {
        const cpus = std.Thread.getCpuCount() catch 4;
        return .{
            .gpa = gpa,
            .index = index,
            .threads = @min(@max(cpus, 1), 16),
        };
    }

    pub fn deinit(self: *Searcher) void {
        self.last_query.deinit(self.gpa);
        self.last_results.deinit(self.gpa);
        self.ranked.deinit(self.gpa);
    }

    pub fn invalidate(self: *Searcher) void {
        self.has_last = false;
    }

    fn canNarrow(self: *const Searcher, text: []const u8) bool {
        if (!self.has_last) return false;
        if (self.last_count != self.index.count()) return false;
        const prev = self.last_query.items;
        if (prev.len == 0 or text.len <= prev.len) return false;
        if (!std.mem.startsWith(u8, text, prev)) return false;
        // '?' matches exactly one character and '"' flips a term to exact, so
        // either one can widen a term instead of tightening it.
        if (std.mem.indexOfScalar(u8, text, '?') != null) return false;
        return std.mem.indexOfScalar(u8, text, '"') == null;
    }

    /// Runs `text` and returns the `limit` best matches, ranked. The slice
    /// belongs to the searcher and stays valid until the next search.
    pub fn search(self: *Searcher, text: []const u8, limit: usize) ![]const Match {
        const timer = w.Timer.start();
        const q = try parseQuery(self.gpa, text, .{ .default_kind = self.default_kind });
        defer freeQuery(self.gpa, q);

        const narrow = self.canNarrow(text);
        self.narrowed = false;

        var results: std.ArrayList(Match) = .empty;
        errdefer results.deinit(self.gpa);

        if (q.isEmpty()) {
            self.mode = .name;
            const lens = self.index.entries.slice().items(.name_len);
            const run = self.span();
            try results.ensureTotalCapacity(self.gpa, run.to - run.from);
            for (run.from..run.to) |i| {
                if (lens[i] == 0) continue;
                results.appendAssumeCapacity(.{ .entry = @intCast(i), .score = 0 });
            }
            try self.newUnderScope(&results);
        } else if (q.has_path_terms) {
            self.mode = .path;
            try self.freshenPathBlooms();
            const cands = self.candidatesFor(narrow, .path);
            self.narrowed = cands != null;
            try self.runShards(&results, q, .path, cands);
            if (cands == null) try self.scanNewUnderScope(&results, q, .path);
        } else {
            self.mode = .name;
            const cands = self.candidatesFor(narrow, .name);
            self.narrowed = cands != null;
            try self.runShards(&results, q, .name, cands);
            if (cands == null) try self.scanNewUnderScope(&results, q, .name);

            // Names alone barely answered it, so the query is probably spread
            // across directories. Every name match is also a path match, so the
            // second pass replaces the first rather than adding to it.
            const threshold = @max(limit, path_fallback_below);
            if (q.can_use_paths and results.items.len < threshold) {
                try self.freshenPathBlooms();
                var wide: std.ArrayList(Match) = .empty;
                errdefer wide.deinit(self.gpa);
                const path_cands = self.candidatesFor(narrow, .path);
                try self.runShards(&wide, q, .path, path_cands);
                if (path_cands == null) try self.scanNewUnderScope(&wide, q, .path);
                if (wide.items.len >= results.items.len) {
                    results.deinit(self.gpa);
                    results = wide;
                    self.mode = .path;
                    self.narrowed = path_cands != null;
                } else {
                    wide.deinit(self.gpa);
                }
            }
        }

        self.last_query.clearRetainingCapacity();
        try self.last_query.appendSlice(self.gpa, text);
        self.last_results.deinit(self.gpa);
        self.last_results = results;
        self.has_last = true;
        self.last_count = self.index.count();
        self.last_mode = self.mode;

        try self.rank(limit);
        self.last_nanos = timer.readNanos();
        return self.ranked.items;
    }

    /// Total matches for the last query, before the display limit.
    pub fn total(self: *const Searcher) usize {
        return self.last_results.items.len;
    }

    /// Ranks further into the last search's matches, for scrolling past what
    /// was asked for the first time. Every match is already in hand, so this
    /// costs one pass over them rather than searching again.
    pub fn extend(self: *Searcher, want: usize) ![]const Match {
        const have = self.ranked.items.len;
        if (want <= have or have >= self.total()) return self.ranked.items;
        try self.rank(want);
        return self.ranked.items;
    }

    /// Sorts the last search's matches another way. Which files matched has
    /// not changed, only their order, so clicking a column costs one ranking
    /// pass and no search at all.
    pub fn setOrder(self: *Searcher, order: Order, limit: usize) ![]const Match {
        const timer = w.Timer.start();
        self.order = order;
        try self.rank(limit);
        // The number on screen now measures a ranking pass rather than the
        // search that filled the list, and that one was not narrowed.
        self.narrowed = false;
        self.last_nanos = timer.readNanos();
        return self.ranked.items;
    }

    /// Entries under the scope that the change journal added after the layout
    /// was built. They sit past every subtree run, so the range scan misses
    /// them and they have to be gathered by walking parent chains.
    fn newUnderScope(self: *Searcher, into: *std.ArrayList(Match)) !void {
        const scope = self.scope orelse return;
        var i = self.index.ordered;
        while (i < self.index.count()) : (i += 1) {
            if (self.index.isDead(i)) continue;
            if (self.index.descendsFrom(i, scope.from)) {
                try into.append(self.gpa, .{ .entry = i, .score = 0 });
            }
        }
    }

    /// Matches the same query against those newly added entries and appends the
    /// hits, so a scoped search sees a file created a moment ago.
    fn scanNewUnderScope(self: *Searcher, out: *std.ArrayList(Match), q: Query, mode: Mode) !void {
        if (self.scope == null or self.index.count() <= self.index.ordered) return;

        var fresh: std.ArrayList(Match) = .empty;
        defer fresh.deinit(self.gpa);
        try self.newUnderScope(&fresh);
        if (fresh.items.len == 0) return;

        try self.runShards(out, q, mode, fresh.items);
    }

    /// The cached result set, if narrowing over it would actually be cheaper
    /// than rescanning. Past a quarter of the index the random access into the
    /// entry arrays costs more than streaming through all of them.
    fn candidatesFor(self: *const Searcher, narrow: bool, mode: Mode) ?[]const Match {
        if (!narrow or self.last_mode != mode) return null;
        const cands = self.last_results.items;
        const run = self.span();
        if (!worthNarrowing(cands.len, run.to - run.from)) return null;
        return cands;
    }

    /// A renamed directory moves a whole subtree, leaving every path bloom and
    /// stored path under it wrong, which would hide those files from a search.
    fn freshenPathBlooms(self: *Searcher) !void {
        if (self.index.layout_stale) try self.index.refreshLayout();
    }

    /// Keeps the k best matches in a bounded heap, so a query matching half the
    /// drive costs one linear pass instead of sorting a million rows. Sorting
    /// by a column goes through here too: only the comparison changes.
    fn rank(self: *Searcher, limit: usize) !void {
        const all = self.last_results.items;
        const k = if (limit == 0) all.len else @min(limit, all.len);
        self.ranked.clearRetainingCapacity();
        try self.ranked.ensureTotalCapacity(self.gpa, k);
        if (k == 0) return;

        const by: Ranking = .{ .index = self.index, .order = self.order };
        const heap = self.ranked.addManyAsSliceAssumeCapacity(k);
        @memcpy(heap, all[0..k]);
        // Min-heap by rank, so the root is the worst of the k kept so far.
        var i = k / 2;
        while (i > 0) {
            i -= 1;
            siftDown(by, heap, i);
        }
        for (all[k..]) |m| {
            if (by.better(m, heap[0])) {
                heap[0] = m;
                siftDown(by, heap, 0);
            }
        }
        std.sort.pdq(Match, heap, by, Ranking.lessThan);
    }

    fn runShards(
        self: *Searcher,
        out: *std.ArrayList(Match),
        q: Query,
        mode: Mode,
        candidates: ?[]const Match,
    ) !void {
        const run = self.span();
        // Narrowing walks a candidate list, so its indices start at zero. A
        // fresh scan walks entries, so it starts wherever the scope does.
        const base: u32 = if (candidates == null) run.from else 0;
        const count: u32 = if (candidates) |c| @intCast(c.len) else run.to - run.from;
        if (count == 0) return;

        // Below this, starting threads costs more than the split saves.
        const n: usize = if (count < 20_000) 1 else self.threads;

        const shards = try self.gpa.alloc(Shard, n);
        defer {
            for (shards) |*s| s.out.deinit(self.gpa);
            self.gpa.free(shards);
        }

        const per = count / @as(u32, @intCast(n));
        for (shards, 0..) |*s, k| {
            const from: u32 = base + per * @as(u32, @intCast(k));
            const to: u32 = if (k == n - 1) base + count else from + per;
            s.* = .{
                .index = self.index,
                .query = q,
                .gpa = self.gpa,
                .mode = mode,
                .from = from,
                .to = to,
                .candidates = if (candidates) |c| c[from..to] else null,
            };
        }

        if (n == 1) {
            shards[0].run();
        } else {
            const handles = try self.gpa.alloc(std.Thread, n);
            defer self.gpa.free(handles);
            var spawned: usize = 0;
            for (shards[1..], handles[1..]) |*s, *hnd| {
                hnd.* = std.Thread.spawn(.{}, Shard.run, .{s}) catch break;
                spawned += 1;
            }
            shards[0].run();
            for (handles[1 .. 1 + spawned]) |hnd| hnd.join();
            // A shard that failed to spawn still has to be scanned.
            for (shards[1 + spawned ..]) |*s| s.run();
        }

        var total_out: usize = 0;
        for (shards) |*s| {
            if (s.err) |e| return e;
            total_out += s.out.items.len;
        }
        // Unused, not total: a scoped search calls this a second time for the
        // entries added since the layout was built, and appends to the same list.
        try out.ensureUnusedCapacity(self.gpa, total_out);
        for (shards) |*s| out.appendSliceAssumeCapacity(s.out.items);
    }
};

fn siftDown(by: Ranking, heap: []Match, start: usize) void {
    var root = start;
    while (true) {
        var child = root * 2 + 1;
        if (child >= heap.len) return;
        if (child + 1 < heap.len and by.better(heap[child], heap[child + 1])) child += 1;
        if (!by.better(heap[root], heap[child])) return;
        std.mem.swap(Match, &heap[root], &heap[child]);
        root = child;
    }
}

test "glob anchors both ends" {
    try std.testing.expect(globMatch("main.zig", "*.zig"));
    try std.testing.expect(globMatch("main.zig", "main.*"));
    try std.testing.expect(globMatch("main.zig", "m?in.zig"));
    try std.testing.expect(!globMatch("main.zig", "*.zag"));
    try std.testing.expect(!globMatch("main.zig", "main"));
    try std.testing.expect(globMatch("MAIN.ZIG", "*.zig"));
}

test "substring ignores case" {
    try std.testing.expect(containsIgnoreCase("README.md", "readme"));
    try std.testing.expect(containsIgnoreCase("xREADMEx", "readme"));
    try std.testing.expect(!containsIgnoreCase("READM", "readme"));
    try std.testing.expect(containsIgnoreCase("anything", ""));
}

test "top k keeps the best and drops the rest" {
    const gpa = std.testing.allocator;
    var index = idx.Index.init(gpa);
    defer index.deinit();
    var searcher = Searcher.init(gpa, &index);
    defer searcher.deinit();

    var all: std.ArrayList(Match) = .empty;
    defer all.deinit(gpa);
    for (0..1000) |i| try all.append(gpa, .{ .entry = @intCast(i), .score = @intCast(i) });
    searcher.last_results = all;
    try searcher.rank(10);
    defer {
        all = searcher.last_results;
        searcher.last_results = .empty;
    }

    try std.testing.expectEqual(@as(usize, 10), searcher.ranked.items.len);
    for (searcher.ranked.items, 0..) |m, i| {
        try std.testing.expectEqual(@as(i32, @intCast(999 - i)), m.score);
    }
}

/// The names on a set of matches, in the order they came back, so an ordering
/// test reads as the list it is checking.
fn namesOf(index: *const Index, hits: []const Match, into: [][]const u8) [][]const u8 {
    for (hits, 0..) |m, i| into[i] = index.nameOf(m.entry);
    return into[0..hits.len];
}

test "sorting by name ignores case and turns around" {
    const gpa = std.testing.allocator;
    var index = idx.Index.init(gpa);
    defer index.deinit();
    const root = try idx.addForTest(&index, std.math.maxInt(u32), "C:", true);
    try index.volumes.append(gpa, .{ .letter = 'C', .root = root });
    for ([_][]const u8{ "beta.txt", "Alpha.txt", "gamma.txt" }) |name| {
        _ = try idx.addForTest(&index, root, name, false);
    }

    var searcher = Searcher.init(gpa, &index);
    defer searcher.deinit();

    var buf: [8][]const u8 = undefined;
    searcher.order = .{ .by = .name };
    // Upper case sorting first would put Alpha above beta for the wrong reason,
    // so the drive letter, which is upper case too, stays out of it.
    _ = try searcher.search("txt", 8);
    try std.testing.expectEqualDeep(
        @as([]const []const u8, &.{ "Alpha.txt", "beta.txt", "gamma.txt" }),
        namesOf(&index, searcher.ranked.items, &buf),
    );

    _ = try searcher.setOrder(.{ .by = .name, .descending = true }, 8);
    try std.testing.expectEqualDeep(
        @as([]const []const u8, &.{ "gamma.txt", "beta.txt", "Alpha.txt" }),
        namesOf(&index, searcher.ranked.items, &buf),
    );
}

test "sorting a column keeps the folders above the files" {
    const gpa = std.testing.allocator;
    var index = idx.Index.init(gpa);
    defer index.deinit();
    const root = try idx.addForTest(&index, std.math.maxInt(u32), "C:", true);
    try index.volumes.append(gpa, .{ .letter = 'C', .root = root });
    _ = try idx.addForTest(&index, root, "build", true);
    const log = try idx.addForTest(&index, root, "build.log", false);
    _ = try idx.addForTest(&index, root, "abuild.txt", false);
    _ = try idx.addForTest(&index, root, "zbuild", true);

    // The biggest file of the lot, so a size sort has every reason to lift it
    // above the folders if it is going to.
    index.entries.items(.size)[log] = 1 << 30;

    var searcher = Searcher.init(gpa, &index);
    defer searcher.deinit();

    var buf: [8][]const u8 = undefined;
    searcher.order = .{ .by = .name };
    _ = try searcher.search("build", 8);
    try std.testing.expectEqualDeep(
        @as([]const []const u8, &.{ "build", "zbuild", "abuild.txt", "build.log" }),
        namesOf(&index, searcher.ranked.items, &buf),
    );

    // Turning it around turns each group around and leaves the groups where
    // they are, which is the half of this that is easy to get wrong.
    _ = try searcher.setOrder(.{ .by = .name, .descending = true }, 8);
    try std.testing.expectEqualDeep(
        @as([]const []const u8, &.{ "zbuild", "build", "build.log", "abuild.txt" }),
        namesOf(&index, searcher.ranked.items, &buf),
    );

    _ = try searcher.setOrder(.{ .by = .size, .descending = true }, 8);
    try std.testing.expectEqualDeep(
        @as([]const []const u8, &.{ "build", "zbuild", "build.log", "abuild.txt" }),
        namesOf(&index, searcher.ranked.items, &buf),
    );

    // Ranking by the query is answering a different question, so it mixes them
    // and the exact name wins outright.
    _ = try searcher.setOrder(.{}, 8);
    try std.testing.expectEqualStrings("build", index.nameOf(searcher.ranked.items[0].entry));
}

test "sorting by path puts a directory's files together" {
    const gpa = std.testing.allocator;
    var index = idx.Index.init(gpa);
    defer index.deinit();
    const root = try idx.addForTest(&index, std.math.maxInt(u32), "C:", true);
    try index.volumes.append(gpa, .{ .letter = 'C', .root = root });
    // Added out of order, and the two directories interleave by name, so
    // nothing here comes out right by accident.
    const zed = try idx.addForTest(&index, root, "zed", true);
    const apps = try idx.addForTest(&index, root, "apps", true);
    _ = try idx.addForTest(&index, zed, "b.log", false);
    _ = try idx.addForTest(&index, apps, "c.log", false);
    _ = try idx.addForTest(&index, zed, "a.log", false);

    var searcher = Searcher.init(gpa, &index);
    defer searcher.deinit();
    searcher.order = .{ .by = .path };

    const hits = try searcher.search("log", 8);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("C:\\apps\\c.log", index.path(hits[0].entry, &buf));
    try std.testing.expectEqualStrings("C:\\zed\\a.log", index.path(hits[1].entry, &buf));
    try std.testing.expectEqualStrings("C:\\zed\\b.log", index.path(hits[2].entry, &buf));
}

test "sorting by size or date survives the next query" {
    const gpa = std.testing.allocator;
    var index = idx.Index.init(gpa);
    defer index.deinit();
    const root = try idx.addForTest(&index, std.math.maxInt(u32), "C:", true);
    try index.volumes.append(gpa, .{ .letter = 'C', .root = root });
    const small = try idx.addForTest(&index, root, "small.bin", false);
    const huge = try idx.addForTest(&index, root, "huge.bin", false);
    const middling = try idx.addForTest(&index, root, "middling.bin", false);

    const sizes = index.entries.items(.size);
    const times = index.entries.items(.modified);
    sizes[small] = 10;
    sizes[huge] = 1 << 40;
    sizes[middling] = 4096;
    // Backwards against the sizes, so one ordering cannot pass as the other.
    times[small] = 300;
    times[huge] = 100;
    times[middling] = 200;

    var searcher = Searcher.init(gpa, &index);
    defer searcher.deinit();

    var buf: [8][]const u8 = undefined;
    _ = try searcher.search("bin", 8);
    searcher.order = .{ .by = .size, .descending = true };
    // A second query, not a re-rank: a column stays clicked across searches.
    _ = try searcher.search("bin", 8);
    try std.testing.expectEqualDeep(
        @as([]const []const u8, &.{ "huge.bin", "middling.bin", "small.bin" }),
        namesOf(&index, searcher.ranked.items, &buf),
    );

    _ = try searcher.setOrder(.{ .by = .modified, .descending = true }, 8);
    try std.testing.expectEqualDeep(
        @as([]const []const u8, &.{ "small.bin", "middling.bin", "huge.bin" }),
        namesOf(&index, searcher.ranked.items, &buf),
    );
}

/// Small tree used by the matching tests:
///   C:\src\main.zig
///   C:\src\domain_zigzag_generator.txt
///   C:\docs\main.zig
///   C:\notes.md
fn buildTree(index: *Index) !void {
    const root = try idx.addForTest(index, std.math.maxInt(u32), "C:", true);
    // orderDepthFirst walks out from the registered volumes, and findPath looks
    // a drive up in them, so a tree without one is not a faithful index.
    try index.volumes.append(index.gpa, .{ .letter = 'C', .root = root });
    const src = try idx.addForTest(index, root, "src", true);
    const docs = try idx.addForTest(index, root, "docs", true);
    _ = try idx.addForTest(index, src, "main.zig", false);
    _ = try idx.addForTest(index, src, "domain_zigzag_generator.txt", false);
    _ = try idx.addForTest(index, docs, "main.zig", false);
    _ = try idx.addForTest(index, root, "notes.md", false);
}

test "a query spread across directories falls back to paths" {
    const gpa = std.testing.allocator;
    var index = idx.Index.init(gpa);
    defer index.deinit();
    try buildTree(&index);

    var searcher = Searcher.init(gpa, &index);
    defer searcher.deinit();

    // Nothing is named anything like "srcmainzg", so only a path can answer it.
    const hits = try searcher.search("srcmainzg", 10);
    try std.testing.expectEqual(Mode.path, searcher.mode);
    try std.testing.expect(hits.len >= 1);

    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("C:\\src\\main.zig", index.path(hits[0].entry, &buf));
}

test "a scope keeps a search inside one directory" {
    const gpa = std.testing.allocator;
    var index = idx.Index.init(gpa);
    defer index.deinit();
    try buildTree(&index);
    // Subtree runs only exist once entries are in depth-first order.
    try index.orderDepthFirst();

    var searcher = Searcher.init(gpa, &index);
    defer searcher.deinit();

    // main.zig lives in both src and docs.
    try std.testing.expectEqual(@as(usize, 2), (try searcher.search("main.zig", 10)).len);

    const docs = index.findPath("C:\\docs").?;
    searcher.setScope(index.subtree(docs));
    const inside = try searcher.search("main.zig", 10);
    try std.testing.expectEqual(@as(usize, 1), inside.len);

    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("C:\\docs\\main.zig", index.path(inside[0].entry, &buf));

    // Nothing in docs is called notes.md, though the drive has one.
    try std.testing.expectEqual(@as(usize, 0), (try searcher.search("notes.md", 10)).len);

    searcher.setScope(null);
    try std.testing.expectEqual(@as(usize, 1), (try searcher.search("notes.md", 10)).len);
}

test "a scope narrows as more is typed" {
    const gpa = std.testing.allocator;
    var index = idx.Index.init(gpa);
    defer index.deinit();
    try buildTree(&index);
    try index.orderDepthFirst();

    var searcher = Searcher.init(gpa, &index);
    defer searcher.deinit();
    searcher.setScope(index.subtree(index.findPath("C:/src").?));

    // Narrowing walks the previous results, which are already inside the scope.
    // Both files in src match, since domain_zigzag_generator.txt holds m, a, i
    // and n in order, and the tighter one still ranks first.
    _ = try searcher.search("mai", 10);
    const hits = try searcher.search("main", 10);
    try std.testing.expectEqual(@as(usize, 2), hits.len);

    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("C:\\src\\main.zig", index.path(hits[0].entry, &buf));
}

test "a scope picks up a file added after the layout was built" {
    const gpa = std.testing.allocator;
    var index = idx.Index.init(gpa);
    defer index.deinit();
    try buildTree(&index);
    try index.orderDepthFirst();

    const docs = index.findPath("C:\\docs").?;
    const src = index.findPath("C:\\src").?;

    var searcher = Searcher.init(gpa, &index);
    defer searcher.deinit();
    searcher.setScope(index.subtree(docs));
    try std.testing.expectEqual(@as(usize, 0), (try searcher.search("later.md", 10)).len);

    // The journal appends, so this lands past the end of every subtree run and
    // the range scan alone would never reach it.
    _ = try idx.addForTest(&index, docs, "later.md", false);
    searcher.invalidate();

    const hits = try searcher.search("later.md", 10);
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("C:\\docs\\later.md", index.path(hits[0].entry, &buf));

    // An empty query lists it too: docs, the main.zig in it, and the new file.
    _ = try searcher.search("", 100);
    try std.testing.expectEqual(@as(usize, 3), searcher.total());

    // A file added outside the scope stays outside it.
    _ = try idx.addForTest(&index, src, "later.md", false);
    searcher.invalidate();
    try std.testing.expectEqual(@as(usize, 1), (try searcher.search("later.md", 10)).len);
}

test "extending keeps the ranking it already showed" {
    const gpa = std.testing.allocator;
    var index = idx.Index.init(gpa);
    defer index.deinit();
    try buildTree(&index);
    try index.orderDepthFirst();

    var searcher = Searcher.init(gpa, &index);
    defer searcher.deinit();

    const first = try searcher.search("", 3);
    try std.testing.expectEqual(@as(usize, 3), first.len);
    var head: [3]Match = undefined;
    @memcpy(&head, first);

    // Ranking further has to agree with what the user already scrolled past,
    // otherwise rows would shuffle under them as they page down.
    const more = try searcher.extend(100);
    try std.testing.expectEqual(searcher.total(), more.len);
    try std.testing.expectEqualSlices(Match, &head, more[0..3]);

    // Asking for less than is already ranked leaves it alone.
    const same = try searcher.extend(2);
    try std.testing.expectEqual(more.len, same.len);
}

test "an empty query lists only the scope" {
    const gpa = std.testing.allocator;
    var index = idx.Index.init(gpa);
    defer index.deinit();
    try buildTree(&index);
    try index.orderDepthFirst();

    var searcher = Searcher.init(gpa, &index);
    defer searcher.deinit();

    _ = try searcher.search("", 100);
    try std.testing.expectEqual(@as(usize, 7), searcher.total());

    const src = index.findPath("C:\\src").?;
    searcher.setScope(index.subtree(src));
    _ = try searcher.search("", 100);
    // src itself, plus the two files in it.
    try std.testing.expectEqual(@as(usize, 3), searcher.total());
}

test "the tightest match ranks first" {
    const gpa = std.testing.allocator;
    var index = idx.Index.init(gpa);
    defer index.deinit();
    try buildTree(&index);

    var searcher = Searcher.init(gpa, &index);
    defer searcher.deinit();

    const hits = try searcher.search("mainzg", 10);
    try std.testing.expect(hits.len >= 2);
    try std.testing.expectEqualStrings("main.zig", index.nameOf(hits[0].entry));
}

test "exact mode rejects what fuzzy accepts" {
    const gpa = std.testing.allocator;
    var index = idx.Index.init(gpa);
    defer index.deinit();
    try buildTree(&index);

    var searcher = Searcher.init(gpa, &index);
    defer searcher.deinit();

    _ = try searcher.search("mainzg", 10);
    try std.testing.expect(searcher.total() > 0);

    searcher.default_kind = .exact;
    searcher.invalidate();
    _ = try searcher.search("mainzg", 10);
    try std.testing.expectEqual(@as(usize, 0), searcher.total());

    searcher.invalidate();
    _ = try searcher.search("main.zig", 10);
    try std.testing.expectEqual(@as(usize, 2), searcher.total());
}

test "every term has to match, and a term with a separator matches the path" {
    const gpa = std.testing.allocator;
    var index = idx.Index.init(gpa);
    defer index.deinit();
    try buildTree(&index);

    var searcher = Searcher.init(gpa, &index);
    defer searcher.deinit();
    searcher.default_kind = .exact;

    _ = try searcher.search("main.zig", 10);
    try std.testing.expectEqual(@as(usize, 2), searcher.total());

    searcher.invalidate();
    _ = try searcher.search("src\\main.zig", 10);
    try std.testing.expectEqual(Mode.path, searcher.mode);
    try std.testing.expectEqual(@as(usize, 1), searcher.total());

    searcher.invalidate();
    _ = try searcher.search("main.zig zzz", 10);
    try std.testing.expectEqual(@as(usize, 0), searcher.total());
}

test "narrowing gives the same answer as a cold search" {
    const gpa = std.testing.allocator;
    var index = idx.Index.init(gpa);
    defer index.deinit();

    // Narrowing only kicks in while the candidate set stays well under the
    // index, so most of these entries have to miss the query.
    const root = try idx.addForTest(&index, std.math.maxInt(u32), "C:", true);
    var buf: [32]u8 = undefined;
    for (0..2000) |i| {
        const name = if (i % 8 == 0)
            try std.fmt.bufPrint(&buf, "file_{d}_report.txt", .{i})
        else
            try std.fmt.bufPrint(&buf, "unmatched_{d}.dat", .{i});
        _ = try idx.addForTest(&index, root, name, false);
    }

    var searcher = Searcher.init(gpa, &index);
    defer searcher.deinit();

    searcher.invalidate();
    _ = try searcher.search("rep", 10);
    try std.testing.expectEqual(Mode.name, searcher.mode);
    _ = try searcher.search("report", 10);
    try std.testing.expect(searcher.narrowed);
    const narrowed_total = searcher.total();

    searcher.invalidate();
    _ = try searcher.search("report", 10);
    try std.testing.expect(!searcher.narrowed);
    try std.testing.expectEqual(searcher.total(), narrowed_total);
}

test "a killed entry stops matching" {
    const gpa = std.testing.allocator;
    var index = idx.Index.init(gpa);
    defer index.deinit();
    try buildTree(&index);

    var searcher = Searcher.init(gpa, &index);
    defer searcher.deinit();
    searcher.default_kind = .exact;

    const before = try searcher.search("main.zig", 10);
    try std.testing.expectEqual(@as(usize, 2), searcher.total());
    index.kill(before[0].entry);

    searcher.invalidate();
    _ = try searcher.search("main.zig", 10);
    try std.testing.expectEqual(@as(usize, 1), searcher.total());
}

test {
    _ = score;
}

test "a match smeared across a deep path is not a hit" {
    const gpa = std.testing.allocator;
    var index = idx.Index.init(gpa);
    defer index.deinit();

    const root = try idx.addForTest(&index, std.math.maxInt(u32), "C:", true);

    // One file whose name holds the query outright.
    _ = try idx.addForTest(&index, root, "abcdefghi.txt", false);

    // One buried deep enough that the query is a subsequence of its path by
    // sheer accident, spread over nine directories.
    var parent = root;
    for ("abcdefghi") |c| {
        const dir = [_]u8{c} ** 8;
        parent = try idx.addForTest(&index, parent, &dir, true);
    }
    _ = try idx.addForTest(&index, parent, "notes.txt", false);

    var searcher = Searcher.init(gpa, &index);
    defer searcher.deinit();

    const hits = try searcher.search("abcdefghi", 10);
    try std.testing.expectEqual(@as(usize, 1), searcher.total());

    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings("C:" ++ "\\" ++ "abcdefghi.txt", index.path(hits[0].entry, &buf));
}

test "resuming a parent's match agrees with matching each path whole" {
    const gpa = std.testing.allocator;
    var index = idx.Index.init(gpa);
    defer index.deinit();

    const root = try idx.addForTest(&index, std.math.maxInt(u32), "C:", true);
    const users = try idx.addForTest(&index, root, "Users", true);
    const dev = try idx.addForTest(&index, users, "dev", true);
    const src = try idx.addForTest(&index, dev, "src", true);
    _ = try idx.addForTest(&index, src, "main.zig", false);
    _ = try idx.addForTest(&index, src, "search.zig", false);
    _ = try idx.addForTest(&index, src, "index.zig", false);
    _ = try idx.addForTest(&index, dev, "srcmain.txt", false);
    _ = try idx.addForTest(&index, root, "main.zig", false);

    const queries = [_][]const u8{
        "srcmainzg",  "main",       "\"main.zig\"", "src\\main",
        "*.zig",      "devsrc zig", "zzz",                "userssrcindex",
    };

    var full_buf: [1024]u8 = undefined;
    var parent_buf: [1024]u8 = undefined;
    var state: [max_cached_terms]TermState = undefined;

    for (queries) |text| {
        const q = try parseQuery(gpa, text, .{});
        defer freeQuery(gpa, q);
        const parents = index.entries.slice().items(.parent);

        for (0..index.count()) |raw| {
            const i: u32 = @intCast(raw);
            const parent = parents[i];
            if (parent == i) continue;

            const name = index.nameOf(i);
            const full = index.path(i, &full_buf);
            const prefix = index.path(parent, &parent_buf);

            primeTerms(q, prefix, state[0..q.terms.len]);
            const resumed = scoreResumed(full, name, prefix.len, q, state[0..q.terms.len]);
            try std.testing.expectEqual(scorePath(full, name, q), resumed);
        }
    }
}
