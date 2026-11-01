const std = @import("std");
const build_options = @import("build_options");
const w = @import("win32.zig");
const console = @import("console.zig");
const explorer = @import("explorer.zig");
const idx = @import("index.zig");
const mft = @import("mft.zig");
const ntfs = @import("ntfs.zig");
const search = @import("search.zig");
const sizer_mod = @import("sizer.zig");
const startup = @import("startup.zig");
const usn = @import("usn.zig");
const synth = @import("synth.zig");
const install = @import("install.zig");
const pipe = @import("pipe.zig");
const shell = @import("shell.zig");

const usage =
    \\ElephantSearch - instant filename search over the NTFS master file table.
    \\
    \\Usage: elephant [options] [query...]
    \\
    \\  -d, --drive LETTER   index only this drive, repeatable (default: every NTFS volume)
    \\  -n, --limit N        results to print (default 50)
    \\  -u, --under DIR      only match under this directory
    \\  -l, --long           print the size and date alongside each path
    \\  -e, --exact          plain terms match contiguously instead of fuzzily
    \\  -i, --interactive    keep searching after the first query
    \\      --plain          read whole lines instead of searching as you type
    \\      --rebuild        read the drives again instead of using the cache
    \\      --bench          time a fixed set of queries against the index
    \\      --synthetic N    index N made up entries instead of a real drive
    \\      --order ORDER    tree or scattered, how synthetic entries are laid
    \\                       out (default scattered, which is what an MFT scan
    \\                       produces)
    \\      --fanout K       files per synthetic directory (default 8). A real
    \\                       tree has a long tail of directories holding one or
    \\                       two files, so 2 is the honest case to measure
    \\      --add-to-explorer, --remove-from-explorer
    \\                       put "Search with ElephantSearch" in Explorer's own
    \\                       right click menu, on folders and on drives, or
    \\                       take it back out
    \\      --install-service, --uninstall-service
    \\                       install the background service that reads the
    \\                       drives, so searching needs no administrator rights,
    \\                       or take it off again. Both ask for those rights once
    \\      --service-pipe NAME
    \\                       read the drives through a service listening on NAME
    \\                       instead of the installed one, for testing. Never
    \\                       loads or saves the saved index
    \\      --version        show which version this is
    \\  -h, --help           show this
    \\
    \\With a console attached the results follow every keystroke. Arrows move
    \\through them, enter opens the selection, shift+enter shows it in
    \\Explorer, and escape clears the query before it quits. With --plain, or
    \\when input is piped, every line is one query instead.
    \\
    \\Commands start with a colon, which no file name can contain: :quit,
    \\:exact and :fuzzy to switch how plain terms match, :help for the rest.
    \\The plain prompt also takes :n COUNT to change how many results print, and
    \\:in DIR to search under one directory, or everywhere again without one.
    \\
    \\Terms are separated by spaces and all of them have to match. A plain term
    \\matches fuzzily, so "srcmainzg" finds src\main.zig, and the tightest match
    \\ranks first. Quoting a term with "" makes it contiguous, * and ? make it a
    \\wildcard pattern anchored at both ends, and a term holding \ or / matches
    \\the full path instead of the name. Matching ignores case throughout.
    \\
    \\Reading the MFT needs administrator rights, or the service installed with
    \\--install-service.
    \\
;

const Options = struct {
    drives: std.ArrayList(u8) = .empty,
    limit: usize = 50,
    long: bool = false,
    under: ?[]const u8 = null,
    interactive: bool = false,
    plain: bool = false,
    rebuild: bool = false,
    bench: bool = false,
    synthetic: u32 = 0,
    order: synth.Order = .scattered,
    fanout: u32 = 8,
    kind: search.Kind = .fuzzy,
    query: std.ArrayList(u8) = .empty,
    /// Set by the two flags that only touch Explorer's menu and never index
    /// anything.
    menu: ?enum { add, remove } = null,
    service: ?install.Change = null,
    service_pipe: ?[:0]const u16 = null,
};

/// Prints what bringing the index up reported, which is the whole of what the
/// console shows before the first search.
const Reporter = struct {
    out: *std.Io.Writer,

    fn watcher(self: *Reporter) startup.Watcher {
        return .{ .ctx = self, .on = on };
    }

    fn on(ctx: *anyopaque, ev: startup.Event) void {
        const self: *Reporter = @ptrCast(@alignCast(ctx));
        self.write(ev) catch {};
    }

    fn write(self: *Reporter, ev: startup.Event) !void {
        const out = self.out;
        switch (ev) {
            .synthetic => |s| try out.print("{d} synthetic entries laid out {t} in {d} ms\n", .{
                s.entries,
                s.order,
                s.millis,
            }),
            .restored => |r| try out.print(
                "{d} entries from the cache in {d} ms, catching up from the journal\n",
                .{ r.entries, r.millis },
            ),
            .frozen => |f| {
                var day_buf: [16]u8 = undefined;
                try out.print(
                    "{d} entries from the cache saved {s}, in {d} ms. The drives need an elevated terminal\n" ++
                        "to open, so this is the index as it was saved and it will not update.\n",
                    .{ f.entries, startup.day(&day_buf, f.saved), f.millis },
                );
            },
            // A terminal shows the line that follows the moment it lands, so
            // announcing the drive first would only ever be read on the one
            // that hangs, and that one says nothing new.
            .reading => {},
            .scanned => |s| try out.print("{c}: {d} entries in {d} ms\n", .{
                s.letter,
                s.entries,
                s.millis,
            }),
            .failed => |f| switch (f.reason) {
                error.AccessDenied => try out.print(
                    "{c}: access denied. Reading the MFT needs an elevated terminal.\n",
                    .{f.letter},
                ),
                error.OpenFailed => try out.print("{c}: could not open the volume\n", .{f.letter}),
                error.EnumFailed => try out.print("{c}: MFT enumeration failed\n", .{f.letter}),
                error.ServiceFailed => try out.print("{c}: the service stopped answering\n", .{f.letter}),
            },
            .ready => |r| try out.print(
                "{d} entries indexed in {d} ms, about {d} MiB resident\n\n",
                .{ r.entries, r.millis, r.bytes / (1024 * 1024) },
            ),
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    var out_buf: [64 * 1024]u8 = undefined;
    var out_file = std.Io.File.stdout().writer(io, &out_buf);
    const out = &out_file.interface;
    defer out.flush() catch {};

    const argv = try init.minimal.args.toSlice(arena);

    var opts: Options = .{};
    defer opts.drives.deinit(gpa);
    defer opts.query.deinit(gpa);

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            try out.writeAll(usage);
            return;
        } else if (std.mem.eql(u8, a, "--version")) {
            try out.writeAll("ElephantSearch " ++ build_options.version ++ "\n");
            return;
        } else if (std.mem.eql(u8, a, "-d") or std.mem.eql(u8, a, "--drive")) {
            i += 1;
            if (i >= argv.len or argv[i].len == 0) return fail(out, "--drive needs a letter\n", .{});
            try opts.drives.append(gpa, std.ascii.toUpper(argv[i][0]));
        } else if (std.mem.eql(u8, a, "-n") or std.mem.eql(u8, a, "--limit")) {
            i += 1;
            if (i >= argv.len) return fail(out, "--limit needs a number\n", .{});
            opts.limit = std.fmt.parseInt(usize, argv[i], 10) catch
                return fail(out, "--limit needs a number, got {s}\n", .{argv[i]});
        } else if (std.mem.eql(u8, a, "-u") or std.mem.eql(u8, a, "--under")) {
            i += 1;
            if (i >= argv.len) return fail(out, "--under needs a directory\n", .{});
            opts.under = explorer.folderArgument(argv[i]);
        } else if (std.mem.eql(u8, a, "-l") or std.mem.eql(u8, a, "--long")) {
            opts.long = true;
        } else if (std.mem.eql(u8, a, "-e") or std.mem.eql(u8, a, "--exact")) {
            opts.kind = .exact;
        } else if (std.mem.eql(u8, a, "-i") or std.mem.eql(u8, a, "--interactive")) {
            opts.interactive = true;
        } else if (std.mem.eql(u8, a, "--plain")) {
            opts.plain = true;
        } else if (std.mem.eql(u8, a, "--rebuild")) {
            opts.rebuild = true;
        } else if (std.mem.eql(u8, a, "--bench")) {
            opts.bench = true;
        } else if (std.mem.eql(u8, a, "--add-to-explorer")) {
            opts.menu = .add;
        } else if (std.mem.eql(u8, a, "--remove-from-explorer")) {
            opts.menu = .remove;
        } else if (std.mem.eql(u8, a, "--install-service")) {
            opts.service = .install;
        } else if (std.mem.eql(u8, a, "--uninstall-service")) {
            opts.service = .uninstall;
        } else if (std.mem.eql(u8, a, "--service-pipe")) {
            i += 1;
            if (i >= argv.len) return fail(out, "--service-pipe needs a pipe name\n", .{});
            opts.service_pipe = std.unicode.wtf8ToWtf16LeAllocZ(arena, argv[i]) catch
                return fail(out, "--service-pipe needs a pipe name\n", .{});
        } else if (std.mem.eql(u8, a, "--synthetic")) {
            i += 1;
            if (i >= argv.len) return fail(out, "--synthetic needs a count\n", .{});
            opts.synthetic = std.fmt.parseInt(u32, argv[i], 10) catch
                return fail(out, "--synthetic needs a count, got {s}\n", .{argv[i]});
        } else if (std.mem.eql(u8, a, "--fanout")) {
            i += 1;
            if (i >= argv.len) return fail(out, "--fanout needs a count\n", .{});
            opts.fanout = std.fmt.parseInt(u32, argv[i], 10) catch
                return fail(out, "--fanout needs a count, got {s}\n", .{argv[i]});
            if (opts.fanout == 0) return fail(out, "--fanout needs at least 1\n", .{});
        } else if (std.mem.eql(u8, a, "--order")) {
            i += 1;
            if (i >= argv.len) return fail(out, "--order needs tree or scattered\n", .{});
            opts.order = if (std.mem.eql(u8, argv[i], "tree"))
                .tree
            else if (std.mem.eql(u8, argv[i], "scattered"))
                .scattered
            else
                return fail(out, "--order needs tree or scattered, got {s}\n", .{argv[i]});
        } else if (a.len > 1 and a[0] == '-') {
            return fail(out, "unknown option {s}\n", .{a});
        } else {
            if (opts.query.items.len > 0) try opts.query.append(gpa, ' ');
            try opts.query.appendSlice(gpa, a);
        }
    }

    if (opts.menu) |change| {
        switch (change) {
            .add => explorer.add(gpa) catch |e| return fail(out, "{s}\n", .{whyMenuFailed(e)}),
            .remove => explorer.remove() catch |e| return fail(out, "{s}\n", .{whyMenuFailed(e)}),
        }
        try out.writeAll(switch (change) {
            .add => "right clicking a folder or a drive now offers \"Search with ElephantSearch\"\n",
            .remove => "the entry is out of Explorer's menu\n",
        });
        return;
    }

    if (opts.service) |change| {
        const exe = explorer.besideThis(gpa, "elephant.exe") catch
            return fail(out, "could not find where elephant.exe is\n", .{});
        defer gpa.free(exe);
        const outcome = install.applyElevated(gpa, null, exe, change);
        try out.print("{s}\n", .{outcome.describe()});
        try out.flush();
        // The exit code is how an unelevated run that started this one learns
        // what happened, since it cannot see this console.
        std.process.exit(@intFromEnum(outcome));
    }

    var index = idx.Index.init(gpa);
    defer index.deinit();

    const choice: pipe.Choice = if (opts.synthetic > 0)
        .{ .source = .direct, .service = .elevated }
    else
        pipe.choose(gpa, shell.isElevated(), if (opts.service_pipe) |name| .{ .name = name, .verify = false } else null);
    switch (choice.service) {
        .used => try out.writeAll("reading the drives through the service\n"),
        .outdated => try out.writeAll(
            "the service is another version than this program, so it is not used. " ++
                "elephant --install-service updates it\n",
        ),
        .untrusted => try out.writeAll(
            "something other than the ElephantSearch service holds its pipe, so it is not used\n",
        ),
        .missing => if (opts.service_pipe != null) {
            try out.writeAll("nothing answered on that pipe\n");
        },
        .elevated => {},
    }

    var reporter: Reporter = .{ .out = out };
    const ready = startup.bringUp(gpa, &index, .{
        .drives = opts.drives.items,
        .rebuild = opts.rebuild,
        .synthetic = opts.synthetic,
        .order = opts.order,
        .fanout = opts.fanout,
        .source = choice.source,
        .use_cache = opts.service_pipe == null,
    }, reporter.watcher()) catch |e| switch (e) {
        error.NoVolume => return fail(out, "no NTFS volume found\n", .{}),
        // Every drive already said why on its own line, so there is nothing
        // left to add here.
        error.NothingIndexed => {
            if (choice.service == .missing and opts.service_pipe == null) {
                try out.writeAll("elephant --install-service lets it read them without an elevated terminal.\n");
            }
            try out.flush();
            std.process.exit(1);
        },
        else => return e,
    };
    defer if (ready.cache_path) |p| gpa.free(p);
    if (ready.frozen and choice.service == .missing) {
        try out.writeAll("elephant --install-service lets it read them without an elevated terminal.\n");
    }
    try out.flush();

    // Sizes and dates come off the raw table, which is gigabytes of reading on
    // a big volume. Nothing in the search path needs them, so they fill in
    // behind the interface rather than holding up the first query.
    var sizer = sizer_mod.Sizer.init(gpa, &index, choice.source);
    defer sizer.stop();
    // A restored index already carries whatever the last run read.
    if (opts.synthetic == 0 and !ready.restored) sizer.start();

    var searcher = search.Searcher.init(gpa, &index);
    defer searcher.deinit();
    searcher.default_kind = opts.kind;

    if (opts.under) |dir| {
        const at = index.findPath(dir) orelse return fail(out, "nothing indexed at {s}\n", .{dir});
        if (!index.isDir(at)) return fail(out, "{s} is a file, not a directory\n", .{dir});
        searcher.setScope(index.subtree(at));
    }

    if (opts.bench) {
        try runBench(out, &searcher);
        return;
    }

    if (opts.query.items.len > 0) {
        try runQuery(out, &searcher, &index, opts.query.items, opts.limit, opts.long);
        if (!opts.interactive) return;
    }

    var monitor = usn.Monitor.init(gpa, &index, choice.source);
    defer monitor.deinit();

    // Reported here rather than on screen during the search, because the
    // interface gives the status line to whatever happened most recently and a
    // single keystroke would take this away before it was read.
    defer {
        // Idempotent, and it settles the count and the clock whether or not the
        // cache defer already did it.
        sizer.stop();
        const sizing = sizer.progress();
        if (sizing.wanted > 0) {
            out.print("\n{d} sizes and dates read in {d}.{d:0>1} s{s}", .{
                sizing.filled,
                sizing.millis / 1000,
                (sizing.millis % 1000) / 100,
                if (sizing.finished) "" else ", stopped early",
            }) catch {};
            if (sizing.filled == 0) {
                out.print(" (table holds {d} records, {d} bytes read)", .{
                    sizing.records,
                    sizing.scanned,
                }) catch {};
            }
            if (sizing.trouble.len > 0) {
                out.print(", stopped by {s}", .{sizing.trouble}) catch {};
                if (sizing.failed > 0) {
                    out.print(" on {d} volume{s}", .{
                        sizing.failed,
                        if (sizing.failed == 1) "" else "s",
                    }) catch {};
                }
            }
            out.writeAll("\n") catch {};
            out.flush() catch {};
        }
    }

    // Saving last, and only after the watchers have stopped and everything they
    // queued has been applied, so the journal position written down really is
    // the point the saved index was caught up to.
    defer {
        monitor.stop();
        sizer.stop();
        _ = monitor.drain() catch 0;
        startup.saveCache(&index, ready, gpa);
    }

    const watched = if (opts.synthetic > 0 or ready.frozen) 0 else try monitor.start();
    if (ready.frozen) {
        try out.writeAll("\n");
    } else if (watched > 0) {
        try out.print("watching {d} journal{s} for changes\n\n", .{
            watched,
            if (watched == 1) "" else "s",
        });
    } else {
        try out.writeAll("no active change journal, the index will not update\n\n");
    }

    if (!opts.plain) {
        // Falls through to the line prompt when stdout is a pipe or the console
        // is too old to move a cursor.
        if (console.run(gpa, out, &searcher, &index, &monitor, &sizer, frozenSince(ready))) |_| {
            return;
        } else |e| switch (e) {
            error.NoConsole => {},
            else => return e,
        }
    }

    try prompt(out, io, &searcher, &index, &monitor, opts.limit, opts.long);
}

fn frozenSince(ready: startup.Ready) ?i64 {
    return if (ready.frozen) ready.saved else null;
}

fn whyMenuFailed(e: explorer.Error) []const u8 {
    return switch (e) {
        error.WindowMissing => "elephant-gui.exe has to sit next to elephant.exe, since it is what the menu entry opens",
        error.RegistryFailed => "the registry refused the change",
        error.OutOfMemory => "out of memory",
    };
}

fn fail(out: *std.Io.Writer, comptime fmt: []const u8, args: anytype) !void {
    try out.print(fmt, args);
    try out.flush();
    std.process.exit(2);
}

/// Prints a file time in the machine's own zone, or blanks the column when the
/// record never carried one.
fn printDate(out: *std.Io.Writer, ft: i64) !void {
    var local: i64 = 0;
    const shifted = if (w.FileTimeToLocalFileTime(&ft, &local) != 0) local else ft;
    const d = mft.breakDown(shifted) orelse return out.writeAll("                ");
    try out.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{ d.year, d.month, d.day, d.hour, d.minute });
}

fn runQuery(
    out: *std.Io.Writer,
    searcher: *search.Searcher,
    index: *idx.Index,
    text: []const u8,
    limit: usize,
    long: bool,
) !void {
    const results = try searcher.search(text, limit);

    var path_buf: [32 * 1024]u8 = undefined;
    const slice = index.entries.slice();
    for (results) |m| {
        const path = index.path(m.entry, &path_buf);
        if (!long) {
            try out.print("{s}\n", .{path});
            continue;
        }
        // Ask the file system for the rows actually being printed. The
        // background pass may not have reached them, and for a few dozen rows
        // this is faster than waiting for it.
        const stat = ntfs.statPath(index.gpa, path) orelse ntfs.Stat{
            .size = slice.items(.size)[m.entry],
            .modified = slice.items(.modified)[m.entry],
        };
        try out.print("{d: >14}  ", .{stat.size});
        try printDate(out, stat.modified);
        try out.print("  {s}\n", .{path});
    }

    const micros = searcher.last_nanos / 1000;
    try out.print("\n{d} results in {d}.{d:0>3} ms{s}", .{
        searcher.total(),
        micros / 1000,
        micros % 1000,
        if (searcher.narrowed) " (narrowed)" else "",
    });
    if (results.len < searcher.total()) {
        try out.print(", showing the top {d}", .{results.len});
    }
    try out.writeAll("\n");
    try out.flush();
}

/// Runs a `:` command. Returns true when the prompt should stop.
fn command(
    out: *std.Io.Writer,
    searcher: *search.Searcher,
    index: *idx.Index,
    limit: *usize,
    rest: []const u8,
) !bool {
    var it = std.mem.tokenizeScalar(u8, rest, ' ');
    const name = it.next() orelse "";

    if (std.mem.eql(u8, name, "q") or std.mem.eql(u8, name, "quit") or std.mem.eql(u8, name, "exit")) {
        return true;
    } else if (std.mem.eql(u8, name, "exact")) {
        searcher.default_kind = .exact;
        searcher.invalidate();
        try out.writeAll("plain terms now match contiguously\n");
    } else if (std.mem.eql(u8, name, "fuzzy")) {
        searcher.default_kind = .fuzzy;
        searcher.invalidate();
        try out.writeAll("plain terms now match fuzzily\n");
    } else if (std.mem.eql(u8, name, "n")) {
        const arg = it.next() orelse {
            try out.print("showing {d} results, pass a count to change it\n", .{limit.*});
            return false;
        };
        limit.* = std.fmt.parseInt(usize, arg, 10) catch {
            try out.print(":n needs a number, got {s}\n", .{arg});
            return false;
        };
        try out.print("showing {d} results\n", .{limit.*});
    } else if (std.mem.eql(u8, name, "in")) {
        // The rest of the line rather than the next word, since a directory
        // name can hold spaces.
        const dir = std.mem.trim(u8, it.rest(), " ");
        if (dir.len == 0) {
            searcher.setScope(null);
            try out.writeAll("searching every drive again\n");
        } else if (index.findPath(dir)) |at| {
            if (index.isDir(at)) {
                const found = index.subtree(at);
                searcher.setScope(found);
                try out.print("searching {d} entries under {s}\n", .{ found.to - found.from, dir });
            } else {
                try out.print("{s} is a file, not a directory\n", .{dir});
            }
        } else {
            try out.print("nothing indexed at {s}\n", .{dir});
        }
    } else if (std.mem.eql(u8, name, "help") or std.mem.eql(u8, name, "?")) {
        try out.writeAll(usage);
    } else {
        try out.print("unknown command :{s}, try :help\n", .{name});
    }
    try out.flush();
    return false;
}

fn prompt(
    out: *std.Io.Writer,
    io: std.Io,
    searcher: *search.Searcher,
    index: *idx.Index,
    monitor: *usn.Monitor,
    start_limit: usize,
    long: bool,
) !void {
    var limit = start_limit;
    var in_buf: [4096]u8 = undefined;
    var in_file = std.Io.File.stdin().reader(io, &in_buf);
    const in = &in_file.interface;

    while (true) {
        try out.writeAll("> ");
        try out.flush();
        // Inclusive, because the exclusive form leaves the newline in the
        // buffer and every later read comes back empty.
        const line = in.takeDelimiterInclusive('\n') catch |e| switch (e) {
            error.EndOfStream => break,
            // No query is that long, and searching the first part of it would
            // answer something nobody asked.
            error.StreamTooLong => {
                _ = in.discardDelimiterInclusive('\n') catch |d| switch (d) {
                    error.EndOfStream => break,
                    else => return d,
                };
                try out.print("skipped a line longer than the {d} bytes a query can hold\n", .{in_buf.len});
                continue;
            },
            else => return e,
        };
        const text = std.mem.trim(u8, line, " \r\n\t");
        if (text.len == 0) continue;
        // A file name cannot hold a colon, so nothing searchable is shadowed.
        if (text[0] == ':') {
            if (try command(out, searcher, index, &limit, text[1..])) break;
            continue;
        }

        // Fold in whatever the journal reported since the last query. Doing it
        // here means no lock has to guard the index during a search.
        const changed = try monitor.drain();
        if (changed > 0) {
            searcher.invalidate();
            try out.print("({d} file change{s} picked up)\n", .{
                changed,
                if (changed == 1) "" else "s",
            });
        }
        if (monitor.lost.load(.acquire)) {
            try out.writeAll("(a change journal wrapped, the index is stale until a rescan)\n");
        }

        try runQuery(out, searcher, index, text, limit, long);
    }
    try out.writeAll("\n");
    try out.flush();
}

fn runBench(out: *std.Io.Writer, searcher: *search.Searcher) !void {
    const queries = [_][]const u8{
        "a",         "zi",          "zig",           "zig.e",
        "zig.exe",   "e",           "ex",            "exe",
        "*.exe",     "readme",      "config",        "notfoundxyzzy",
        "png",       "srcmainzg",   "srcmainzig",    "elephantsearch",
        "src/main",  "downloads",
    };

    try out.writeAll("query              mode   matches         cold      narrowed\n");
    try out.writeAll("------------------------------------------------------------\n");
    for (queries) |q| {
        searcher.invalidate();
        _ = try searcher.search(q, 50);
        const cold_us = searcher.last_nanos / 1000;
        const n = searcher.total();
        const mode = searcher.mode;

        // Warm the cache with the query minus its last character, then measure
        // the keystroke that completes it.
        var narrow_us: u64 = 0;
        if (q.len > 1) {
            searcher.invalidate();
            _ = try searcher.search(q[0 .. q.len - 1], 50);
            _ = try searcher.search(q, 50);
            if (searcher.narrowed) narrow_us = searcher.last_nanos / 1000;
        }

        try out.print("{s: <18} {t: <5} {d: >8}  {d: >5}.{d:0>3} ms", .{
            q, mode, n, cold_us / 1000, cold_us % 1000,
        });
        if (narrow_us > 0) {
            try out.print("  {d: >5}.{d:0>3} ms\n", .{ narrow_us / 1000, narrow_us % 1000 });
        } else {
            try out.writeAll("            -\n");
        }
    }
    try out.flush();
}

test {
    _ = @import("cache.zig");
    _ = @import("console.zig");
    // The window has no root of its own in the test build, so it hangs here.
    _ = @import("gui.zig");
    _ = @import("explorer.zig");
    _ = @import("icons.zig");
    _ = @import("shell.zig");
    _ = @import("startup.zig");
    _ = @import("ntfs.zig");
    _ = @import("mft.zig");
    _ = @import("synth.zig");
    _ = @import("search.zig");
    _ = @import("score.zig");
    _ = @import("highlight.zig");
    _ = @import("index.zig");
    _ = @import("volume.zig");
    _ = @import("pipe.zig");
    _ = @import("usn.zig");
    _ = @import("sizer.zig");
    _ = @import("install.zig");
}
