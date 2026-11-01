//! As-you-type console front end.
//!
//! The whole loop is deliberately dumb: take whatever keys are already waiting,
//! run one search, repaint the entire frame. A cold query costs about 20 ms and
//! most keystrokes narrow the previous result set in well under 5, so there is
//! nothing to debounce and no worker thread to coordinate with.
//!
//! Layout decisions live in `render`, which draws a `View` of plain strings. It
//! never touches the console, so a frame can be rendered into a buffer and
//! checked in a test.

const std = @import("std");
const w = @import("win32.zig");
const idx = @import("index.zig");
const search = @import("search.zig");
const usn = @import("usn.zig");
const sizer_mod = @import("sizer.zig");
const startup = @import("startup.zig");
const shell = @import("shell.zig");

/// Title, query, two rules and the status line.
const chrome_rows: usize = 5;

/// Results kept for scrolling. Ranking more than this costs more than anyone
/// scrolls through, and the status line owns up when a query overflows it.
const pool: usize = 500;

const prompt_prefix = "> ";

/// How long to sit on the input handle before looking at the change journal
/// again. Short enough that a new file feels immediate, long enough that an
/// idle window costs nothing.
const idle_wake_ms: w.DWORD = 300;

/// Least time between two refreshes caused by the journal rather than by a
/// keystroke. A busy machine writes files continuously, and re-running a query
/// over three million entries for each one would burn a core to show nothing.
const change_settle_ms: u64 = 1000;

/// Runs the interface until the user leaves. Returns `error.NoConsole` when
/// stdin and stdout are not a console pair, which is the caller's cue to fall
/// back to the line-oriented prompt.
pub fn run(
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    searcher: *search.Searcher,
    index: *idx.Index,
    monitor: *usn.Monitor,
    sizer: *sizer_mod.Sizer,
    /// When the cache was saved, if the index is that cache taken as it was
    /// because the drives would not open to catch it up.
    frozen: ?i64,
) !void {
    var ui = try Ui.begin(gpa, out, searcher, index, monitor, sizer);
    ui.frozen = frozen;
    defer ui.end();

    try ui.refresh();
    while (ui.running) {
        if (try ui.pump()) try ui.refresh();
    }
}

const Command = struct {
    name: []const u8,
    help: []const u8,
};

const commands = [_]Command{
    .{ .name = "exact", .help = "plain terms match contiguously" },
    .{ .name = "fuzzy", .help = "plain terms match with gaps allowed" },
    .{ .name = "help", .help = "what the keys and the query syntax do" },
    .{ .name = "in", .help = "search under one directory, or everywhere again with no path" },
    .{ .name = "quit", .help = "leave, which drops the index" },
};

const help_text = [_][]const u8{
    "",
    "  Results follow what you type. Every term has to match, and matching",
    "  ignores case throughout.",
    "",
    "    plain        letters in order with gaps allowed, so srcmainzg",
    "                 finds src\\main.zig, and the tightest match ranks first",
    "    \"quoted\"     contiguous instead",
    "    *.zig        a wildcard pattern, anchored at both ends",
    "    src\\main     a term holding a slash matches the whole path",
    "",
    "    up down      move through the results",
    "    page up/dn   move a screen at a time",
    "    enter        open the selected file",
    "    shift+enter  show it in Explorer instead",
    "    ctrl+c       copy its full path",
    "    esc          clear the query, or leave once it is already empty",
    "    ctrl+q       leave",
    "",
    "  A colon starts a command, which no file name can, so nothing you might",
    "  search for is out of reach:",
    "",
    "    :in C:\\Users   search only under that directory",
    "    :in            search every drive again",
    "    :exact :fuzzy  switch how plain terms match",
    "    :quit          leave",
    "",
};

/// Which list the body is showing. The query decides: a leading colon means
/// commands, and only :help swaps in the help text.
const Pane = enum { results, commands, help };

const Ui = struct {
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    searcher: *search.Searcher,
    index: *idx.Index,
    monitor: *usn.Monitor,
    sizer: *sizer_mod.Sizer,
    frozen: ?i64 = null,

    input: w.HANDLE,
    screen: w.HANDLE,
    saved_input_mode: w.DWORD,
    saved_screen_mode: w.DWORD,
    saved_cp: u32,

    query: std.ArrayList(u8) = .empty,
    /// Byte offset of the caret inside `query`.
    cursor: usize = 0,
    selected: usize = 0,
    /// First visible row of the body.
    top: usize = 0,
    /// Body rows the last frame had room for, which is what a page key moves.
    body: usize = 1,
    cols: usize = 80,
    lines: usize = 25,

    /// A high surrogate waiting for its pair. Anything outside the basic plane
    /// arrives as two key events.
    pending_surrogate: u16 = 0,

    results: []const search.Match = &.{},
    /// Set when the query changed and the results no longer answer it.
    stale: bool = true,
    help_open: bool = false,
    running: bool = true,
    /// Since the last refresh the change journal asked for.
    since_change: w.Timer = undefined,

    /// One-off message shown in place of the status until the next edit.
    note_buf: [160]u8 = undefined,
    note_len: usize = 0,

    row_bytes: std.ArrayList(u8) = .empty,
    row_slices: std.ArrayList([]const u8) = .empty,

    fn begin(
        gpa: std.mem.Allocator,
        out: *std.Io.Writer,
        searcher: *search.Searcher,
        index: *idx.Index,
        monitor: *usn.Monitor,
        sizer: *sizer_mod.Sizer,
    ) !Ui {
        const input = w.GetStdHandle(w.STD_INPUT_HANDLE);
        const screen = w.GetStdHandle(w.STD_OUTPUT_HANDLE);
        if (input == w.INVALID_HANDLE_VALUE or screen == w.INVALID_HANDLE_VALUE) return error.NoConsole;

        // GetConsoleMode only succeeds on a console handle, so this doubles as
        // the test for a redirected pipe.
        var input_mode: w.DWORD = 0;
        var screen_mode: w.DWORD = 0;
        if (w.GetConsoleMode(input, &input_mode) == 0) return error.NoConsole;
        if (w.GetConsoleMode(screen, &screen_mode) == 0) return error.NoConsole;

        // Without virtual terminal processing there is no way to move the
        // cursor, and redrawing a frame per keystroke is hopeless.
        if (w.SetConsoleMode(screen, screen_mode | w.ENABLE_VIRTUAL_TERMINAL_PROCESSING) == 0) {
            return error.NoConsole;
        }
        const raw = w.ENABLE_WINDOW_INPUT | w.ENABLE_EXTENDED_FLAGS;
        if (w.SetConsoleMode(input, raw) == 0) {
            _ = w.SetConsoleMode(screen, screen_mode);
            return error.NoConsole;
        }

        const saved_cp = w.GetConsoleOutputCP();
        _ = w.SetConsoleOutputCP(w.CP_UTF8);

        var ui: Ui = .{
            .gpa = gpa,
            .out = out,
            .searcher = searcher,
            .index = index,
            .monitor = monitor,
            .sizer = sizer,
            .input = input,
            .screen = screen,
            .saved_input_mode = input_mode,
            .saved_screen_mode = screen_mode,
            .saved_cp = saved_cp,
            .since_change = w.Timer.start(),
        };
        ui.measure();

        // The alternate buffer keeps the indexing report and the shell prompt
        // intact underneath, so leaving looks like the app was never here.
        try out.writeAll("\x1b[?1049h\x1b[2J");
        try out.flush();
        return ui;
    }

    fn end(self: *Ui) void {
        self.out.writeAll("\x1b[?25h\x1b[?1049l") catch {};
        self.out.flush() catch {};
        _ = w.SetConsoleOutputCP(self.saved_cp);
        _ = w.SetConsoleMode(self.input, self.saved_input_mode);
        _ = w.SetConsoleMode(self.screen, self.saved_screen_mode);
        self.query.deinit(self.gpa);
        self.row_bytes.deinit(self.gpa);
        self.row_slices.deinit(self.gpa);
    }

    fn measure(self: *Ui) void {
        var info: w.ConsoleScreenBufferInfo = undefined;
        if (w.GetConsoleScreenBufferInfo(self.screen, &info) == 0) return;
        const cols = @as(i32, info.window.right) - info.window.left + 1;
        const lines = @as(i32, info.window.bottom) - info.window.top + 1;
        self.cols = @max(@as(usize, @intCast(@max(cols, 1))), 24);
        self.lines = @max(@as(usize, @intCast(@max(lines, 1))), chrome_rows);
    }

    fn pane(self: *const Ui) Pane {
        if (self.help_open) return .help;
        const q = self.query.items;
        if (q.len > 0 and q[0] == ':') return .commands;
        return .results;
    }

    /// How many rows the current pane can show in total, scrolling included.
    /// For results that is every match, not just the ones ranked so far, since
    /// scrolling into the rest only costs another ranking pass.
    fn count(self: *const Ui) usize {
        return switch (self.pane()) {
            .results => self.searcher.total(),
            .commands => matchingCommands(self.commandPrefix()).len,
            .help => help_text.len,
        };
    }

    /// Whatever follows the verb, which only `:in` uses so far.
    fn commandArg(self: *const Ui) []const u8 {
        const q = self.query.items;
        if (q.len == 0 or q[0] != ':') return "";
        const rest = q[1..];
        const space = std.mem.indexOfScalar(u8, rest, ' ') orelse return "";
        return std.mem.trim(u8, rest[space + 1 ..], " ");
    }

    fn setScope(self: *Ui, path: []const u8) void {
        if (path.len == 0) {
            self.searcher.setScope(null);
            self.note("searching every drive again", .{});
            return;
        }
        const dir = self.index.findPath(path) orelse {
            self.note("nothing indexed at {s}", .{path});
            return;
        };
        if (!self.index.isDir(dir)) {
            self.note("{s} is a file, not a directory", .{path});
            return;
        }
        const found = self.index.subtree(dir);
        self.searcher.setScope(found);
        self.note("searching {d} entries under {s}", .{ found.to - found.from, path });
    }

    fn commandPrefix(self: *const Ui) []const u8 {
        const q = self.query.items;
        if (q.len == 0 or q[0] != ':') return "";
        // Only the verb selects a command; :n 20 style arguments come after it.
        const rest = q[1..];
        const end_of_verb = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
        return rest[0..end_of_verb];
    }

    // ---- input ----

    /// Returns false when the wait ran out with nothing to show for it, so an
    /// idle screen is left alone instead of being repainted for nothing.
    fn pump(self: *Ui) !bool {
        // Waiting on the handle rather than blocking inside the read is what
        // lets a file created in another window appear on its own, instead of
        // on whatever key gets pressed next.
        if (w.WaitForSingleObject(self.input, idle_wake_ms) != w.WAIT_OBJECT_0) {
            // Windows writes files all the time on its own, so folding the
            // journal in on every tick would re-search several times a second
            // for changes nobody was waiting on.
            if (self.monitor.hasPending()) {
                if (self.since_change.readMillis() < change_settle_ms) return false;
                self.since_change = w.Timer.start();
                self.stale = true;
                return true;
            }
            // Sizes are still arriving, so the rows on screen keep changing
            // even though nothing was typed and no file moved.
            return !self.sizer.progress().finished;
        }

        var records: [64]w.InputRecord = undefined;
        var got: w.DWORD = 0;
        if (w.ReadConsoleInputW(self.input, &records, 1, &got) == 0 or got == 0) {
            self.running = false;
            return true;
        }
        self.handle(records[0]);

        // Everything already queued gets folded in before the redraw, so a held
        // backspace or a fast typist costs one search rather than one each.
        while (self.running) {
            var waiting: w.DWORD = 0;
            if (w.GetNumberOfConsoleInputEvents(self.input, &waiting) == 0 or waiting == 0) break;
            const want = @min(waiting, @as(w.DWORD, records.len));
            if (w.ReadConsoleInputW(self.input, &records, want, &got) == 0) break;
            for (records[0..got]) |r| self.handle(r);
        }
        return true;
    }

    fn handle(self: *Ui, r: w.InputRecord) void {
        switch (r.event_type) {
            w.WINDOW_BUFFER_SIZE_EVENT => self.measure(),
            w.KEY_EVENT => {
                const k = r.event.key;
                if (k.key_down == 0) return;
                self.key(k);
            },
            else => {},
        }
    }

    fn key(self: *Ui, k: w.KeyEventRecord) void {
        const state = k.control_key_state;
        const ctrl = state & (w.LEFT_CTRL_PRESSED | w.RIGHT_CTRL_PRESSED) != 0;
        const alt = state & (w.LEFT_ALT_PRESSED | w.RIGHT_ALT_PRESSED) != 0;
        const shift = state & w.SHIFT_PRESSED != 0;

        switch (k.virtual_key_code) {
            w.VK_ESCAPE => {
                if (self.help_open) {
                    self.help_open = false;
                } else if (self.query.items.len > 0) {
                    self.setQuery("");
                } else {
                    // Leaving throws away an index that took seconds to build,
                    // so escape only does it once there is nothing to clear.
                    self.running = false;
                }
                return;
            },
            w.VK_RETURN => {
                self.submit(shift);
                return;
            },
            w.VK_BACK => {
                if (ctrl) self.deleteWord() else self.deleteBack();
                return;
            },
            w.VK_DELETE => {
                self.deleteForward();
                return;
            },
            w.VK_LEFT => {
                self.cursor = if (ctrl) wordStart(self.query.items, self.cursor) else prevChar(self.query.items, self.cursor);
                return;
            },
            w.VK_RIGHT => {
                self.cursor = if (ctrl) wordEnd(self.query.items, self.cursor) else nextChar(self.query.items, self.cursor);
                return;
            },
            w.VK_HOME => {
                if (ctrl) self.moveTo(0) else self.cursor = 0;
                return;
            },
            w.VK_END => {
                if (ctrl) self.moveTo(self.count()) else self.cursor = self.query.items.len;
                return;
            },
            w.VK_UP => {
                self.move(-1);
                return;
            },
            w.VK_DOWN => {
                self.move(1);
                return;
            },
            w.VK_PRIOR => {
                self.move(-@as(isize, @intCast(self.body)));
                return;
            },
            w.VK_NEXT => {
                self.move(@intCast(self.body));
                return;
            },
            else => {},
        }

        if (ctrl and !alt) {
            switch (k.virtual_key_code) {
                // Copy rather than quit, the way every file search does it. The
                // hint line always names a key that leaves, so nobody is stuck.
                'C' => self.copySelected(),
                'Q' => self.running = false,
                'U' => self.setQuery(""),
                'W' => self.deleteWord(),
                'A' => self.cursor = 0,
                'E' => self.cursor = self.query.items.len,
                else => {},
            }
            return;
        }

        self.insertChar(k.char);
    }

    fn insertChar(self: *Ui, unit: u16) void {
        if (unit < 0x20 or unit == 0x7F) return;

        var code: u21 = unit;
        if (unit >= 0xD800 and unit <= 0xDBFF) {
            self.pending_surrogate = unit;
            return;
        }
        if (unit >= 0xDC00 and unit <= 0xDFFF) {
            if (self.pending_surrogate == 0) return;
            const high: u21 = self.pending_surrogate - 0xD800;
            const low: u21 = unit - 0xDC00;
            code = 0x10000 + (high << 10) + low;
            self.pending_surrogate = 0;
        }

        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(code, &buf) catch return;
        self.query.insertSlice(self.gpa, self.cursor, buf[0..n]) catch return;
        self.cursor += n;
        self.edited();
    }

    fn setQuery(self: *Ui, text: []const u8) void {
        self.query.clearRetainingCapacity();
        self.query.appendSlice(self.gpa, text) catch {};
        self.cursor = self.query.items.len;
        self.edited();
    }

    fn cut(self: *Ui, start: usize, stop: usize) void {
        if (stop <= start) return;
        const items = self.query.items;
        std.mem.copyForwards(u8, items[start..], items[stop..]);
        self.query.items.len -= stop - start;
        self.cursor = start;
        self.edited();
    }

    fn deleteBack(self: *Ui) void {
        self.cut(prevChar(self.query.items, self.cursor), self.cursor);
    }

    fn deleteForward(self: *Ui) void {
        const at_cursor = self.cursor;
        self.cut(at_cursor, nextChar(self.query.items, at_cursor));
        self.cursor = at_cursor;
    }

    fn deleteWord(self: *Ui) void {
        self.cut(wordStart(self.query.items, self.cursor), self.cursor);
    }

    fn edited(self: *Ui) void {
        self.stale = true;
        self.help_open = false;
        self.note_len = 0;
        self.selected = 0;
        self.top = 0;
    }

    fn move(self: *Ui, delta: isize) void {
        const n = self.count();
        if (n == 0) {
            self.selected = 0;
            return;
        }
        const at_row: isize = @intCast(self.selected);
        const moved = std.math.clamp(at_row + delta, 0, @as(isize, @intCast(n - 1)));
        self.selected = @intCast(moved);
    }

    fn moveTo(self: *Ui, row: usize) void {
        const n = self.count();
        self.selected = if (n == 0) 0 else @min(row, n - 1);
    }

    // ---- acting on a row ----

    fn submit(self: *Ui, in_explorer: bool) void {
        switch (self.pane()) {
            .help => self.help_open = false,
            .commands => self.runCommand(),
            .results => self.openSelected(in_explorer),
        }
    }

    fn runCommand(self: *Ui) void {
        const hits = matchingCommands(self.commandPrefix());
        if (hits.len == 0) {
            self.note("no command starts with :{s}, try :help", .{self.commandPrefix()});
            return;
        }
        const chosen = hits[@min(self.selected, hits.len - 1)];

        // The argument lives in the query, which is about to be cleared.
        var arg_buf: [4096]u8 = undefined;
        const typed = self.commandArg();
        const arg_len = @min(typed.len, arg_buf.len);
        @memcpy(arg_buf[0..arg_len], typed[0..arg_len]);
        const arg = arg_buf[0..arg_len];

        self.setQuery("");

        if (std.mem.eql(u8, chosen.name, "in")) {
            self.setScope(arg);
        } else if (std.mem.eql(u8, chosen.name, "quit")) {
            self.running = false;
        } else if (std.mem.eql(u8, chosen.name, "help")) {
            self.help_open = true;
        } else if (std.mem.eql(u8, chosen.name, "exact")) {
            self.searcher.default_kind = .exact;
            self.searcher.invalidate();
            self.note("plain terms now match contiguously", .{});
        } else if (std.mem.eql(u8, chosen.name, "fuzzy")) {
            self.searcher.default_kind = .fuzzy;
            self.searcher.invalidate();
            self.note("plain terms now match with gaps allowed", .{});
        }
    }

    fn openSelected(self: *Ui, in_explorer: bool) void {
        if (self.selected >= self.results.len) return;

        var path_buf: [32 * 1024]u8 = undefined;
        const path = self.index.path(self.results[self.selected].entry, &path_buf);

        const ok = if (in_explorer)
            shell.reveal(self.gpa, path)
        else
            shell.open(self.gpa, path);
        if (ok) {
            self.note("{s} {s}", .{ if (in_explorer) "showing" else "opened", baseName(path) });
        } else {
            self.note("could not open {s}", .{baseName(path)});
        }
    }

    fn copySelected(self: *Ui) void {
        if (self.pane() != .results or self.selected >= self.results.len) return;

        var path_buf: [32 * 1024]u8 = undefined;
        const path = self.index.path(self.results[self.selected].entry, &path_buf);
        if (shell.copyText(self.gpa, path)) {
            self.note("copied {s}", .{path});
        } else {
            self.note("could not reach the clipboard", .{});
        }
    }

    fn note(self: *Ui, comptime fmt: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(&self.note_buf, fmt, args) catch self.note_buf[0..0];
        self.note_len = written.len;
    }

    // ---- searching and drawing ----

    fn refresh(self: *Ui) !void {
        if (!self.running) return;

        if (self.stale) {
            try self.runSearch();
            self.stale = false;
        }
        try self.draw();
    }

    fn runSearch(self: *Ui) !void {
        // Folding journal changes in here means no lock has to guard the index
        // while a search runs.
        // The results changing is the whole report. Saying so in words as well
        // just takes the status line away from something more useful.
        if ((self.monitor.drain() catch 0) > 0) self.searcher.invalidate();
        if (self.pane() != .results) {
            self.results = &.{};
            return;
        }
        // An empty query lists the whole drive, the way Everything opens on
        // everything and narrows from there. It costs one pass over the index,
        // which is the same order as searching for a single letter.
        self.results = try self.searcher.search(self.query.items, pool);
    }

    fn draw(self: *Ui) !void {
        const body = self.lines - chrome_rows;
        self.body = @max(body, 1);

        const total = self.count();
        if (self.selected >= total) self.selected = if (total == 0) 0 else total - 1;
        if (self.selected < self.top) self.top = self.selected;
        if (body > 0 and self.selected >= self.top + body) self.top = self.selected - body + 1;
        if (self.top > total) self.top = 0;

        try self.rankFarEnough(self.top + body);
        try self.buildRows(body);

        var title_buf: [1024]u8 = undefined;
        var timing_buf: [64]u8 = undefined;
        var status_buf: [256]u8 = undefined;

        const view: View = .{
            .title = self.titleText(&title_buf),
            .timing = self.timingText(&timing_buf),
            .query = self.query.items,
            .caret = cpLen(self.query.items[0..self.cursor]),
            .rows = self.row_slices.items,
            .selected = if (self.pane() == .help or total == 0)
                null
            else
                self.selected - self.top,
            .status = self.statusText(&status_buf),
            .hint = self.hintText(),
            .cols = self.cols,
            .lines = self.lines,
        };
        try render(self.out, view);
        try self.out.flush();
    }

    /// Ranks deep enough to fill the rows about to be drawn. Doubling rather
    /// than growing by a screen means holding page down costs a handful of
    /// ranking passes over the whole scroll, not one per screen.
    fn rankFarEnough(self: *Ui, want: usize) !void {
        if (self.pane() != .results or want <= self.results.len) return;
        var target = @max(pool, self.results.len);
        while (target < want) target *= 2;
        self.results = try self.searcher.extend(target);
    }

    /// Materialises just the visible rows. A path costs a walk up the parent
    /// chain, so building the whole pool every frame would be waste.
    fn buildRows(self: *Ui, body: usize) !void {
        self.row_bytes.clearRetainingCapacity();
        self.row_slices.clearRetainingCapacity();

        var offsets: [256]struct { off: usize, len: usize } = undefined;
        var n: usize = 0;

        switch (self.pane()) {
            .help => {
                for (help_text[self.top..], 0..) |line, i| {
                    if (i >= body or n == offsets.len) break;
                    const off = self.row_bytes.items.len;
                    try self.row_bytes.appendSlice(self.gpa, line);
                    offsets[n] = .{ .off = off, .len = line.len };
                    n += 1;
                }
            },
            .commands => {
                const hits = matchingCommands(self.commandPrefix());
                for (hits[@min(self.top, hits.len)..], 0..) |c, i| {
                    if (i >= body or n == offsets.len) break;
                    const off = self.row_bytes.items.len;
                    try self.row_bytes.print(self.gpa, "  :{s: <8}{s}", .{ c.name, c.help });
                    offsets[n] = .{ .off = off, .len = self.row_bytes.items.len - off };
                    n += 1;
                }
            },
            .results => {
                var path_buf: [32 * 1024]u8 = undefined;
                const from = @min(self.top, self.results.len);
                for (self.results[from..], 0..) |m, i| {
                    if (i >= body or n == offsets.len) break;
                    const path = self.index.path(m.entry, &path_buf);
                    const off = self.row_bytes.items.len;
                    try self.row_bytes.appendSlice(self.gpa, " ");
                    try self.row_bytes.appendSlice(self.gpa, path);
                    offsets[n] = .{ .off = off, .len = self.row_bytes.items.len - off };
                    n += 1;
                }
            },
        }

        for (offsets[0..n]) |o| {
            try self.row_slices.append(self.gpa, self.row_bytes.items[o.off..][0..o.len]);
        }
    }

    /// The scope belongs here rather than in a note, because it silently
    /// changes what every result on screen means for as long as it is set.
    fn titleText(self: *Ui, buf: []u8) []const u8 {
        const scope = self.searcher.scope orelse
            return std.fmt.bufPrint(buf, "ElephantSearch  {d} files", .{self.index.count()}) catch
                "ElephantSearch";

        var path_buf: [32 * 1024]u8 = undefined;
        const dir = self.index.path(scope.from, &path_buf);
        return std.fmt.bufPrint(buf, "ElephantSearch  under {s}  {d} entries", .{
            dir,
            scope.to - scope.from,
        }) catch "ElephantSearch";
    }

    fn timingText(self: *Ui, buf: []u8) []const u8 {
        // While the background pass is running, the corner is worth more as a
        // progress report than as a stopwatch.
        const sizing = self.sizer.progress();
        if (!sizing.finished and sizing.wanted > 0) {
            const percent = @min(sizing.filled * 100 / sizing.wanted, 99);
            return std.fmt.bufPrint(buf, "reading sizes {d}%", .{percent}) catch "";
        }
        if (self.pane() != .results) return "";
        const micros = self.searcher.last_nanos / 1000;
        return std.fmt.bufPrint(buf, "{d}.{d:0>3} ms{s}", .{
            micros / 1000,
            micros % 1000,
            if (self.searcher.narrowed) " narrowed" else "",
        }) catch "";
    }

    fn statusText(self: *Ui, buf: []u8) []const u8 {
        var writer = std.Io.Writer.fixed(buf);
        self.writeStatus(&writer) catch {};
        return writer.buffered();
    }

    fn writeStatus(self: *Ui, out: *std.Io.Writer) !void {
        if (self.note_len > 0) {
            try out.writeAll(self.note_buf[0..self.note_len]);
        } else switch (self.pane()) {
            .help => try out.writeAll("help"),
            .commands => try out.writeAll("commands"),
            .results => {
                const found = self.searcher.total();
                if (self.query.items.len == 0) {
                    try out.print("{d} files", .{found});
                } else if (found == 0) {
                    try out.writeAll("no matches");
                } else {
                    try out.print("{d} match{s}, {t} mode", .{
                        found,
                        if (found == 1) "" else "es",
                        self.searcher.mode,
                    });
                }
                if (found > 0) try out.print(", on {d}", .{self.selected + 1});
            },
        }

        // A wrapped journal leaves the index quietly wrong, so it has to be on
        // screen for as long as it is true, not just for the frame it happened.
        if (self.monitor.lost.load(.acquire)) {
            try out.writeAll(", stale since a change journal wrapped");
        }
        if (self.frozen) |saved| {
            var day_buf: [16]u8 = undefined;
            try out.print(", index saved {s} and not updating", .{startup.day(&day_buf, saved)});
        }
    }

    fn hintText(self: *const Ui) []const u8 {
        return switch (self.pane()) {
            .help => "esc close",
            .commands => "enter run  esc clear",
            .results => if (self.query.items.len == 0)
                "enter open  ctrl+c copy  ctrl+q quit  :help"
            else
                "enter open  ctrl+c copy  esc clear  ctrl+q quit",
        };
    }
};

fn matchingCommands(prefix: []const u8) []const Command {
    // The table is ordered, so the matches for any prefix are contiguous and
    // the result can stay a slice of it.
    var first: usize = commands.len;
    var last: usize = 0;
    for (commands, 0..) |c, i| {
        if (!std.ascii.startsWithIgnoreCase(c.name, prefix)) continue;
        first = @min(first, i);
        last = i + 1;
    }
    if (first >= last) return commands[0..0];
    return commands[first..last];
}

fn baseName(path: []const u8) []const u8 {
    const cut = std.mem.lastIndexOfAny(u8, path, "\\/") orelse return path;
    return path[cut + 1 ..];
}

// ---- caret movement over UTF-8 ----

fn prevChar(text: []const u8, at_byte: usize) usize {
    var i = at_byte;
    while (i > 0) {
        i -= 1;
        if (text[i] & 0xC0 != 0x80) return i;
    }
    return 0;
}

fn nextChar(text: []const u8, at_byte: usize) usize {
    var i = at_byte;
    if (i >= text.len) return text.len;
    i += 1;
    while (i < text.len and text[i] & 0xC0 == 0x80) i += 1;
    return i;
}

fn wordStart(text: []const u8, at_byte: usize) usize {
    var i = at_byte;
    while (i > 0 and text[i - 1] == ' ') i -= 1;
    while (i > 0 and text[i - 1] != ' ') i -= 1;
    return i;
}

fn wordEnd(text: []const u8, at_byte: usize) usize {
    var i = at_byte;
    while (i < text.len and text[i] == ' ') i += 1;
    while (i < text.len and text[i] != ' ') i += 1;
    return i;
}

// ---- rendering ----

/// One frame's worth of already-decided text. Nothing here knows about the
/// index, the searcher or the console, which is what makes it testable.
pub const View = struct {
    /// Left half of the title bar.
    title: []const u8,
    /// Right half of the title bar, pushed against the edge.
    timing: []const u8,
    query: []const u8,
    /// Caret position inside the query, counted in characters.
    caret: usize,
    /// The visible body rows, already windowed by the caller.
    rows: []const []const u8,
    /// Which of `rows` is highlighted, if any.
    selected: ?usize,
    status: []const u8,
    hint: []const u8,
    cols: usize,
    lines: usize,
};

/// Draws a whole frame. Every row is positioned absolutely and cleared to the
/// end, so nothing has to be erased first and a repaint never flickers.
pub fn render(out: *std.Io.Writer, v: View) !void {
    // One column is left spare, because filling the last cell of the last row
    // scrolls the buffer on some consoles.
    const width = if (v.cols > 1) v.cols - 1 else 1;
    const lines = @max(v.lines, chrome_rows);
    const body = lines - chrome_rows;

    try out.writeAll("\x1b[?25l");

    try at(out, 0);
    try writePair(out, v.title, v.timing, width);

    try at(out, 1);
    try out.writeAll(prompt_prefix);
    const room = width -| prompt_prefix.len;
    const shown = try writeTail(out, v.query, room);
    try out.writeAll("\x1b[K");

    try at(out, 2);
    try writeRepeat(out, '-', width);

    for (0..body) |i| {
        try at(out, 3 + i);
        if (i < v.rows.len) {
            const highlighted = v.selected != null and v.selected.? == i;
            if (highlighted) try out.writeAll("\x1b[7m");
            const used = try writeMiddle(out, v.rows[i], width);
            if (highlighted) {
                try writeRepeat(out, ' ', width - used);
                try out.writeAll("\x1b[27m");
            }
        }
        try out.writeAll("\x1b[K");
    }

    try at(out, lines - 2);
    try writeRepeat(out, '-', width);
    try at(out, lines - 1);
    try writePair(out, v.status, v.hint, width);

    // Leaving the caret in the query is what makes the line feel like a text
    // field rather than a picture of one.
    const caret = @min(v.caret, shown);
    try out.print("\x1b[2;{d}H\x1b[?25h", .{prompt_prefix.len + caret + 1});
}

fn at(out: *std.Io.Writer, row: usize) !void {
    try out.print("\x1b[{d};1H", .{row + 1});
}

fn writeRepeat(out: *std.Io.Writer, byte: u8, n: usize) !void {
    const chunk = [_]u8{byte} ** 64;
    var left = n;
    while (left > chunk.len) : (left -= chunk.len) try out.writeAll(&chunk);
    try out.writeAll(chunk[0..left]);
}

/// Writes `left`, then `right` pushed against the right edge. The left side
/// carries the answer while the right side only reminds, so a line too narrow
/// for both drops the right rather than squeezing the left out of existence.
fn writePair(out: *std.Io.Writer, left: []const u8, right: []const u8, width: usize) !void {
    const right_len = cpLen(right);
    const gap = 2;
    const room = if (width > right_len + gap) width - right_len - gap else 0;
    if (room < @min(cpLen(left), width / 2)) {
        _ = try writeClipped(out, left, width);
        try out.writeAll("\x1b[K");
        return;
    }
    const used = try writeClipped(out, left, room);
    try writeRepeat(out, ' ', width - right_len - used);
    try out.writeAll(right);
    try out.writeAll("\x1b[K");
}

/// Writes at most `width` characters and reports how many went out. Character
/// counts stand in for column counts here, so a row of double-width text can
/// still overrun; every row is repositioned, so the damage stops at that row.
fn writeClipped(out: *std.Io.Writer, text: []const u8, width: usize) !usize {
    const len = cpLen(text);
    if (len <= width) {
        try out.writeAll(text);
        return len;
    }
    try out.writeAll(text[0..cpOffset(text, width)]);
    return width;
}

/// Same, but drops the middle so a long path keeps both its drive and its file
/// name, which are the two ends anyone reads.
fn writeMiddle(out: *std.Io.Writer, text: []const u8, width: usize) !usize {
    const len = cpLen(text);
    if (len <= width) {
        try out.writeAll(text);
        return len;
    }
    if (width < 8) return writeClipped(out, text, width);

    const room = width - 3;
    const head = room / 3;
    const tail = room - head;
    try out.writeAll(text[0..cpOffset(text, head)]);
    try out.writeAll("...");
    try out.writeAll(text[cpOffset(text, len - tail)..]);
    return width;
}

/// Writes the last `width` characters, so a query longer than the line keeps
/// its end, which is where the caret is.
fn writeTail(out: *std.Io.Writer, text: []const u8, width: usize) !usize {
    const len = cpLen(text);
    if (len <= width) {
        try out.writeAll(text);
        return len;
    }
    try out.writeAll(text[cpOffset(text, len - width)..]);
    return width;
}

fn cpLen(text: []const u8) usize {
    var n: usize = 0;
    for (text) |c| {
        if (c & 0xC0 != 0x80) n += 1;
    }
    return n;
}

/// Byte offset of character `k`, or the end of the text if it is shorter.
fn cpOffset(text: []const u8, k: usize) usize {
    var n: usize = 0;
    for (text, 0..) |c, i| {
        if (c & 0xC0 != 0x80) {
            if (n == k) return i;
            n += 1;
        }
    }
    return text.len;
}

// ---- tests ----

const testing = std.testing;

fn renderToBuf(buf: []u8, v: View) ![]const u8 {
    var writer = std.Io.Writer.fixed(buf);
    try render(&writer, v);
    return writer.buffered();
}

const plain_view: View = .{
    .title = "ElephantSearch  10 files",
    .timing = "1.500 ms",
    .query = "zig",
    .caret = 3,
    .rows = &.{},
    .selected = null,
    .status = "2 matches",
    .hint = "esc quit",
    .cols = 40,
    .lines = 10,
};

test "a frame fills every row of the window" {
    var buf: [8 * 1024]u8 = undefined;
    var v = plain_view;
    v.rows = &.{ " C:\\a.zig", " C:\\b.zig" };
    v.selected = 0;
    const frame = try renderToBuf(&buf, v);

    // One position per row, and the caret parked back in the query.
    for (1..v.lines + 1) |row| {
        var needle: [16]u8 = undefined;
        const seq = try std.fmt.bufPrint(&needle, "\x1b[{d};1H", .{row});
        try testing.expect(std.mem.indexOf(u8, frame, seq) != null);
    }
    try testing.expect(std.mem.indexOf(u8, frame, "\x1b[2;6H") != null);
    try testing.expect(std.mem.indexOf(u8, frame, "C:\\b.zig") != null);
}

test "the selected row is the only one in reverse video" {
    var buf: [8 * 1024]u8 = undefined;
    var v = plain_view;
    v.rows = &.{ "one", "two", "three" };
    v.selected = 1;
    const frame = try renderToBuf(&buf, v);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, frame, "\x1b[7m"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, frame, "\x1b[27m"));
}

test "a long path loses its middle, not its name" {
    var buf: [8 * 1024]u8 = undefined;
    var v = plain_view;
    v.cols = 30;
    v.rows = &.{"C:\\projects\\renderer\\assets\\generated\\shaders\\src\\main.zig"};
    const frame = try renderToBuf(&buf, v);
    try testing.expect(std.mem.indexOf(u8, frame, "main.zig") != null);
    try testing.expect(std.mem.indexOf(u8, frame, "...") != null);
    try testing.expect(std.mem.indexOf(u8, frame, "generated") == null);
}

test "a window too small for the body still draws its chrome" {
    var buf: [8 * 1024]u8 = undefined;
    var v = plain_view;
    v.lines = 1;
    v.rows = &.{"never shown"};
    const frame = try renderToBuf(&buf, v);
    try testing.expect(std.mem.indexOf(u8, frame, "never shown") == null);
    try testing.expect(std.mem.indexOf(u8, frame, "esc quit") != null);
}

test "a narrow window keeps the match count and drops the key hints" {
    var buf: [8 * 1024]u8 = undefined;
    var v = plain_view;
    v.cols = 44;
    v.status = "63 matches, path mode";
    v.hint = "enter open  shift+enter reveal  esc clear";
    const frame = try renderToBuf(&buf, v);
    try testing.expect(std.mem.indexOf(u8, frame, "63 matches, path mode") != null);
    try testing.expect(std.mem.indexOf(u8, frame, "esc clear") == null);
}

test "clipping never splits a character" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    _ = try writeClipped(&writer, "éàüñ", 2);
    try testing.expectEqualStrings("éà", writer.buffered());
}

test "caret movement steps over whole characters" {
    const text = "aéb";
    try testing.expectEqual(@as(usize, 1), nextChar(text, 0));
    try testing.expectEqual(@as(usize, 3), nextChar(text, 1));
    try testing.expectEqual(@as(usize, 1), prevChar(text, 3));
    try testing.expectEqual(@as(usize, 4), nextChar(text, 3));
    try testing.expectEqual(@as(usize, 4), nextChar(text, 4));
}

test "word movement stops at the term boundary" {
    const text = "src main zig";
    try testing.expectEqual(@as(usize, 9), wordStart(text, text.len));
    try testing.expectEqual(@as(usize, 4), wordStart(text, 8));
    try testing.expectEqual(@as(usize, 3), wordEnd(text, 0));
    try testing.expectEqual(@as(usize, 8), wordEnd(text, 3));
}

test "a command prefix picks out its commands" {
    try testing.expectEqual(@as(usize, commands.len), matchingCommands("").len);
    try testing.expectEqual(@as(usize, 1), matchingCommands("q").len);
    try testing.expectEqualStrings("quit", matchingCommands("q")[0].name);
    try testing.expectEqualStrings("exact", matchingCommands("EX")[0].name);
    try testing.expectEqual(@as(usize, 0), matchingCommands("zzz").len);
}
