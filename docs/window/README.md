# The window

`elephant-gui.exe` is the same search as the terminal, in a window. Each result has the icon Explorer would show, with columns for the size and the date. It takes the same [keys and commands](../searching/README.md).

## Search box

The search box takes the usual text keys. Ctrl+a selects the query, ctrl+x and ctrl+v cut and paste, and ctrl+z undoes. Ctrl+c copies the text you selected in the box, and the selected result's path when nothing is selected. Pasting or ctrl+a while the results have focus goes back to the search box.

## Sorting

Click a column heading to sort on it. Name and Path sort A to Z while Size and Modified start with the biggest and the newest. Click again to reverse it, and a third time to go back to ranking by how well the query matched. The sort stays while you type.

Folders come first in a sorted list, like in Explorer.

Names compare one character at a time, so `page10.txt` lands above `page9.txt`.

## Right click

Right clicking a result shows Explorer's own menu for that file, so "Open with", "Send to", "Properties" and whatever your other programs added are all there. Open, open path and copy full path are on top.

## Drag and drop

You can drag a result out of the window and drop it on another program, the same as dragging it out of Explorer. For example, drop a markdown file on VS Code to open it there, or drop it in an Explorer folder.

Dropping in a folder does what Explorer would do, so it moves the file when that folder is on the same drive and copies it otherwise. Hold ctrl to copy, shift to move, or alt to make a shortcut. Dragging with the right button asks which one when you let go.

## Position

The window opens where you last closed it, at the same size and maximized if it was. If that spot was on a screen that's no longer plugged in, it opens on one that is. The position is kept in `%LOCALAPPDATA%\ElephantSearch\window.txt`, so deleting that file puts it back to the default.

## Dark mode

It follows the dark mode switch in Settings, even while it's open. `--theme light` or `--theme dark` picks one instead.

## Search from Explorer

```
elephant --add-to-explorer
```

That puts "Search with ElephantSearch" in Explorer's right click menu for folders, the empty space inside a folder, and drives. It opens the window searching only under what you clicked. `--remove-from-explorer` takes it back out.

It needs no administrator rights and only applies to your account. It points at `elephant-gui.exe` where it is now, so run it again if you move the folder.
