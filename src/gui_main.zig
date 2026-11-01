//! Entry point for the window.
//!
//! A separate binary from `elephant.exe` rather than a flag on it, because a
//! windows subsystem program started from a terminal has no console to write
//! to and a console one started from Explorer opens a black rectangle behind
//! the window. Neither can be argued out of it after the fact.

const std = @import("std");
const build_options = @import("build_options");
const explorer = @import("explorer.zig");
const gui = @import("gui.zig");
const ui = @import("win32_ui.zig");

const usage =
    \\ElephantSearch - instant filename search over the NTFS master file table.
    \\
    \\Usage: elephant-gui [options]
    \\
    \\  -d, --drive LETTER   index only this drive, repeatable
    \\                       (default: every NTFS volume)
    \\  -u, --under DIR      only match under this directory
    \\  -e, --exact          plain terms match contiguously instead of fuzzily
    \\      --theme WHICH    system, light or dark (default system, which keeps
    \\                       following the switch in Settings as it changes)
    \\      --rebuild        read the drives again instead of using the cache
    \\      --synthetic N    index N made up entries instead of a real drive
    \\      --order ORDER    tree or scattered, how synthetic entries are laid
    \\                       out (default scattered)
    \\      --fanout K       files per synthetic directory (default 8)
    \\      --service-pipe NAME
    \\                       read the drives through a service listening on NAME
    \\                       instead of the installed one, for testing
    \\      --version        show which version this is
    \\  -h, --help           show this
    \\
    \\Reading the master file table needs administrator rights, or the service
    \\that elephant --install-service puts on the machine. Without either the
    \\window opens on whatever the last elevated run saved, and offers both.
    \\
    \\elephant.exe is the same search in a terminal, and takes more options.
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);

    var drives: std.ArrayList(u8) = .empty;
    defer drives.deinit(gpa);

    var opts: gui.Options = .{};

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            return say(usage, ui.MB_ICONINFORMATION);
        } else if (std.mem.eql(u8, a, "--version")) {
            return say("ElephantSearch " ++ build_options.version, ui.MB_ICONINFORMATION);
        } else if (std.mem.eql(u8, a, "-d") or std.mem.eql(u8, a, "--drive")) {
            i += 1;
            if (i >= argv.len or argv[i].len == 0) return complain("--drive needs a letter");
            try drives.append(gpa, std.ascii.toUpper(argv[i][0]));
        } else if (std.mem.eql(u8, a, "-u") or std.mem.eql(u8, a, "--under")) {
            i += 1;
            if (i >= argv.len) return complain("--under needs a directory");
            opts.under = explorer.folderArgument(argv[i]);
        } else if (std.mem.eql(u8, a, "--theme")) {
            i += 1;
            if (i >= argv.len) return complain("--theme needs system, light or dark");
            opts.appearance = if (std.mem.eql(u8, argv[i], "system"))
                .system
            else if (std.mem.eql(u8, argv[i], "light"))
                .light
            else if (std.mem.eql(u8, argv[i], "dark"))
                .dark
            else
                return complain("--theme needs system, light or dark");
        } else if (std.mem.eql(u8, a, "-e") or std.mem.eql(u8, a, "--exact")) {
            opts.kind = .exact;
        } else if (std.mem.eql(u8, a, "--rebuild")) {
            opts.startup.rebuild = true;
        } else if (std.mem.eql(u8, a, "--service-pipe")) {
            i += 1;
            if (i >= argv.len) return complain("--service-pipe needs a pipe name");
            opts.service_pipe = std.unicode.wtf8ToWtf16LeAllocZ(arena, argv[i]) catch
                return complain("--service-pipe needs a pipe name");
        } else if (std.mem.eql(u8, a, "--synthetic")) {
            i += 1;
            if (i >= argv.len) return complain("--synthetic needs a count");
            opts.startup.synthetic = std.fmt.parseInt(u32, argv[i], 10) catch
                return complain("--synthetic needs a count");
        } else if (std.mem.eql(u8, a, "--fanout")) {
            i += 1;
            if (i >= argv.len) return complain("--fanout needs a count");
            opts.startup.fanout = std.fmt.parseInt(u32, argv[i], 10) catch
                return complain("--fanout needs a count");
            if (opts.startup.fanout == 0) return complain("--fanout needs at least 1");
        } else if (std.mem.eql(u8, a, "--order")) {
            i += 1;
            if (i >= argv.len) return complain("--order needs tree or scattered");
            opts.startup.order = if (std.mem.eql(u8, argv[i], "tree"))
                .tree
            else if (std.mem.eql(u8, argv[i], "scattered"))
                .scattered
            else
                return complain("--order needs tree or scattered");
        } else {
            return complain("unknown option, try --help");
        }
    }
    opts.startup.drives = drives.items;

    try gui.run(gpa, opts);
}

/// Nothing here has a console to write to, so anything the user has to read
/// arrives in a message box or not at all.
fn say(text: []const u8, icon: u32) void {
    var wide: [4096]u16 = undefined;
    const n = std.unicode.wtf8ToWtf16Le(wide[0 .. wide.len - 1], text) catch return;
    wide[n] = 0;
    const title = std.unicode.utf8ToUtf16LeStringLiteral("ElephantSearch");
    _ = ui.MessageBoxW(null, @ptrCast(wide[0..n :0].ptr), title, ui.MB_OK | icon);
}

fn complain(text: []const u8) void {
    say(text, ui.MB_ICONERROR);
}
