# cd-for-me

## Requirements
- abcde `sudo apt install abcde`
- flac `sudo apt install flac`
- GTK4 & Libadwaita GObject Introspection (`sudo apt install gir1.2-gtk-4.0 gir1.2-adw-1 python3-gi`)

### abcde
- eyeD3 `sudo apt install eyed3`
- MP3 encoder `sudo apt install lame`

## Usage

### Desktop GUI (Default)
```bash
ruby main.rb [destination]
```
Launches the native GTK4 / Libadwaita desktop interface (default destination: `~/Musik`).
- Configure the output directory or pick a folder via **Browse…**.
- View all detected optical drives (`Audio CD` and `MP3 CD`), toggle which drives to include, and optionally enter **Author** and **Album / Media Name** (defaults to `Unknown/<timestamp>` when left blank).
- View live progress and expandable command output (`abcde`, `cdparanoia`, `rsync`).
- Automatically ejects each drive when finished.

#### Keyboard Shortcuts
| Shortcut | Action |
| --- | --- |
| `Ctrl+Enter` / `Alt+A` | **Copy / Rip All**: Select all detected drives, fill default `Unknown` / timestamp for blank fields, and start immediately |
| `Alt+S` | **Start Selected**: Copy / rip checked drives |
| `F5` / `Ctrl+R` | **Refresh**: Re-scan optical drives |
| `Alt+B` | **Browse**: Open destination folder chooser |
| `Tab` / `Shift+Tab` | Navigate between controls and input fields |
| `Ctrl+Q` / `Escape` | Quit application (when idle) |

### CLI Mode
```bash
ruby main.rb --cli [destination]
```
Runs the classic interactive terminal prompt (compatible with `yes | ruby main.rb --cli`).

## Commands
`abcde -d /dev/sr0 -o mp3 -c "./.abcde.conf"`

## ToDo's

- Use cd-paranoias own progress bar as starting point for progress

## AI

All code is 100% human written execpt for abcde.conf because I couldn't be bothered to reduce the template of andrews-corner to options regarding mp3 by hand :)