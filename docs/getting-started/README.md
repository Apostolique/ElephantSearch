# Getting started

ElephantSearch runs on 64-bit Windows 10 and 11, and searches NTFS drives.

## Install

Download the zip from the [releases page](https://github.com/Apostolique/ElephantSearch/releases) and unzip it wherever you like. There is no installer. Keep `elephant.exe`, `elephant-gui.exe` and `elephant-service.exe` in the same folder, since they find each other there.

The programs aren't signed yet, so SmartScreen warns about them the first time. "More info" then "Run anyway" gets past it.

## Install the service

Reading the drives needs administrator rights. The service has them, so you don't need them:

```
elephant --install-service
```

That asks for administrator rights once. After that, every search runs as you with no prompt. [The service](../service/README.md) has the details, including what it means on a shared computer.

## Search

Open `elephant-gui.exe` and start typing.

The first run reads every fixed NTFS drive, which takes about 10 seconds for 3 million files. The window is usable while it reads, and the status line says which drive it's on. Later runs load the saved index in a fraction of a second, then catch up on whatever changed since.

[Searching](../searching/README.md) covers what you can type.

## In a terminal

`elephant.exe` is the same search in a terminal:

```
elephant
```

Passing a query runs it once and prints the results, which is what you want in a script:

```
elephant -n 10 srcmainzg
```

`-d C` searches one drive. `elephant --help` lists every option.

## Without the service

Without the service, run it as administrator. Without either, it opens on the index the last elevated run saved and says which day that was. That index doesn't update until a run that can read the drives catches it up. The window shows "Install the service" and "Run as administrator" in the corner when this happens.

If the index ever looks wrong, `--rebuild` reads the drives again from scratch.

## Try it on a fake drive

`--synthetic` builds a made up drive in memory. It needs no administrator rights and never touches your saved index:

```
elephant-gui --synthetic 300000
```

## Uninstall

1. `elephant --uninstall-service` removes the service.
2. `elephant --remove-from-explorer` removes the Explorer menu entry, if you added it.
3. Delete the folder you unzipped, and `%LOCALAPPDATA%\ElephantSearch` where the index is saved.
