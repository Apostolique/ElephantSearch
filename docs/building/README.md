# Building

You need [Zig 0.16](https://ziglang.org/download/) and Windows. There are no other dependencies.

```
zig build
```

That puts three programs in `zig-out\bin`:

| Program | Is |
| --- | --- |
| `elephant.exe` | the search in a terminal |
| `elephant-gui.exe` | the search in a window |
| `elephant-service.exe` | the service that reads the drives for both |

The default is `ReleaseSafe`. `-Doptimize=ReleaseFast` is about a third faster.

## Tests

`zig build test` runs the tests. They read `$MFT` records written by hand, so they need no administrator rights.

`zig build verify` checks the reader against a real drive. It reads one volume and compares 200 sizes and dates against what Windows reports. It needs administrator rights or the installed service, and skips without them.

## Without administrator rights

`--synthetic N` searches N made up files instead of the drives:

```
elephant --synthetic 200000
```

The service can run in a console with a fake drive on a pipe of its own, so you can test it without installing anything:

```
elephant-service --console --fake 200000
elephant --service-pipe \\.\pipe\ElephantSearch-console
```

Neither one loads or saves your real index.
