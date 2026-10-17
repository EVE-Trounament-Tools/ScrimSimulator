# EVE observer window layout

`core_char_observer.dat` is an EVE client character settings file: the window layout (overview,
Local chat, locked-target bar and the rest) for one observer. It was taken from a Thunderdome
observer. `docs/obs/scrim-recording.json` crops each capture to match this layout. If every
observer uses this file, the OBS crops line up without any adjusting.

It was made for a client with these settings:

- Windowed mode, 2486×1374 window
- UI scale 1.75
- Default chat font size

A different window size or UI scale moves the windows, and you'll have to redo the OBS crops.

In this layout the locked targets sit at the top left of the screen, which is where the OBS
Targets crops look for them. Each Targets source expects one block of brackets, three rows of three
(see [`docs/obs`](../obs/README.md)). Check in each client that its locked targets wrap into that
shape.

## Setup

1. Log each observer character in once with the settings profile you'll use, then quit the client.
   This creates its `core_char_<characterID>.dat`.
2. Find the profile's folder. On Linux with the Flatpak:
   `~/.var/app/com.eveonline.EveOnline/data/<prefix>/drive_c/users/steamuser/AppData/Local/CCP/EVE/c_ccp_eve_<server>/settings_<Profile>/`
   On Windows: `%LOCALAPPDATA%\CCP\EVE\c_ccp_eve_<server>\settings_<Profile>\`.
3. With every client closed, copy `core_char_observer.dat` over each observer's
   `core_char_<characterID>.dat`. Back up the old files first. The client writes its settings back
   when it exits, so a running client would overwrite the copy.

## Overview sort

The layout's overview is sorted by **Name, ascending** (the sort arrow is on the Name column's
header). Keep it that way on every observer: don't click another column's header to re-sort.

- Each pilot then stays in the same row from frame to frame. A Distance sort reshuffles the list
  every second as ships move.
- A row's place in the alphabetical list says whose it is. When something covers a few names
  (most often a hover tooltip from a mouse left resting on the overview), their distances are
  still readable, and `scrim-positions --recover-hidden` (**Recover hidden pilots** in
  `scrim-positions-gui`) names those rows from the readable names above and below them. Without
  that, the observer loses those pilots, and a pilot missing from any one observer gets no
  position at all.

Recovery only names a row when it's certain: exactly as many pilots missing between the two
readable neighbours as there are unreadable rows, with no ship type contradicting them. A frame
not in name order is skipped, and the run warns when most of an observer's frames aren't.
Better still, park the mouse away from the observer clients while recording.

To find a character's ID, open one of its chat logs (`Documents/EVE/logs/Chatlogs/*_<characterID>.txt`)
and check the `Listener:` line in the header for the character name.

The file also holds that character's other client settings, such as inventory and chat channel
state. Those get overwritten too.
