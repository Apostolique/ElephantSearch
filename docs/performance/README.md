# Performance

These numbers come from 3,055,730 files across four drives. The index takes about 190 MiB of memory.

The first run reads the drives in about 10 seconds. Sizes and dates take another 10 seconds after that, in the background while you search. Later runs load the saved index in 122 ms.

| Query | Matches | From scratch | After one more keystroke |
| --- | --- | --- | --- |
| `zig.exe` | 73 | 1.112 ms | 0.019 ms |
| `zig` | 14,080 | 1.741 ms | 1.368 ms |
| `config` | 44,736 | 8.216 ms | 3.192 ms |
| `*.exe` | 12,657 | 13.904 ms | 0.012 ms |
| `src/main` | 420 | 16.558 ms | 0.116 ms |
| `readme` | 163,297 | 17.987 ms | 7.977 ms |

Typing one more letter only checks the results already on screen, which is why the last column is so much smaller.

Broad queries cost the most because there's nothing to rule out. `a` matches 1.87 million files and takes 17.8 ms. The queries you'd actually type are the cheap ones.

`elephant --bench` times a fixed set of queries on your own drives.
