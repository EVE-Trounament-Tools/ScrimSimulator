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
Targets crops look for them. Each Targets source expects one block of brackets: three rows of three
for Targets 1 and 2, and a column of two for Targets 3 (see [`docs/obs`](../obs/README.md)). Check
in each client that its locked targets wrap into the shape its Targets source expects.

## Setup

1. Log each observer character in once with the settings profile you'll use, then quit the client.
   This creates its `core_char_<characterID>.dat`.
2. Find the profile's folder. On Linux with the Flatpak:
   `~/.var/app/com.eveonline.EveOnline/data/<prefix>/drive_c/users/steamuser/AppData/Local/CCP/EVE/c_ccp_eve_<server>/settings_<Profile>/`
   On Windows: `%LOCALAPPDATA%\CCP\EVE\c_ccp_eve_<server>\settings_<Profile>\`.
3. With every client closed, copy `core_char_observer.dat` over each observer's
   `core_char_<characterID>.dat`. Back up the old files first. The client writes its settings back
   when it exits, so a running client would overwrite the copy.

To find a character's ID, open one of its chat logs (`Documents/EVE/logs/Chatlogs/*_<characterID>.txt`)
and check the `Listener:` line in the header for the character name.

The file also holds that character's other client settings, such as inventory and chat channel
state. Those get overwritten too.
