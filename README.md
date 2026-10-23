# Geode Rollback

Geometry Dash on Steam updated to 2.209 and then 2.2091 (October 2026), and [Geode](https://geode-sdk.org/) only works on 2.2081 until its team catches up. This script rolls your Steam copy back to 2.2081 and puts Geode and your mods back, in one command.

No game files are in this repo. The script downloads 2.2081 through your own Steam account.

## Install

Open PowerShell (right-click Start, then Terminal) and paste:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/fsiuhgshiqoih32/geode-rollback/main/install.ps1)))
```

The Steam console opens with the download command already copied. Click the box at the bottom of the Console page, press Ctrl+V, then Enter. The script waits for the download (about 300 MB) and does the rest.

To see what it would do first without changing anything, add ` -DryRun` to the end of the line.

## What it does

1. Backs up your saves (`%LOCALAPPDATA%\GeometryDash\*.dat`) to `%USERPROFILE%\gd-backup-<date>`.
2. Has Steam download 2.2081 (`download_depot 322170 322171 3816559102876907245`).
3. Checks that the download really is 2.2081, using the same exe timestamp Geode checks, then copies it over your install. The old game files are kept in the backup folder.
4. Installs the Geode v5.11.2 loader from the [official release](https://github.com/geode-sdk/geode/releases/tag/v5.11.2), checking its SHA-256 hash.
5. Installs these mods from the Geode index, each checked against the index's published hash. Mods you already have are left alone.

   | Mod | Version |
   | --- | --- |
   | geode.node-ids | 1.23.3 |
   | cvolton.level-id-api | 2.0.0 |
   | cvolton.betterinfo | 4.4.7 |
   | cvolton.misc_bugfixes | 1.11.0 |
   | dankmeme.globed2 | 2.1.4 |
   | eclipse.eclipse-menu | 1.9.4 |
   | fleym.nongd | 3.6.2 |
   | hiimjustin000.more_icons | 2.1.3 |

6. Makes Steam's `appmanifest_322170.acf` read-only so Steam stops re-updating the game.

Running it again is safe: anything already done is skipped.

## Going back to the latest version

Once Geode supports the new version, run:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/fsiuhgshiqoih32/geode-rollback/main/install.ps1))) -Unlock
```

Then in Steam: Geometry Dash > Properties > Installed Files > Verify integrity of game files.

## Options

| Option | What it does |
| --- | --- |
| `-DryRun` | Downloads and checks everything, changes nothing |
| `-Unlock` | Lets Steam update the game again |
| `-NoMods` | Installs Geode only |
| `-NoLock` | Leaves Steam free to update on the next patch |
| `-SteamPath <folder>` | Your Steam folder, if it isn't found automatically |

## Requirements

Windows, Geometry Dash on Steam, and Steam open and signed in. PowerShell 5.1 comes with Windows.

Not affiliated with RobTop Games or the Geode team.

## Licence

MIT
