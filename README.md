# cd-for-me

## Requirements
- abcde `sudo apt install abcde`
- flac `sudo apt install flac`
- GTK4 & Libadwaita GObject Introspection (`gir1.2-gtk-4.0`, `gir1.2-adw-1`, `python3-gi`)

### abcde
- eyeD3 `sudo apt install eyed3`
- MP3 encoder `sudo apt install lame`

### YouTube Music Album Downloader
- yt-dlp `sudo apt install yt-dlp`
- ffmpeg `sudo apt install ffmpeg`

## Usage

### Desktop GUI (Default)
```bash
ruby main.rb [destination]
```
Launches the GTK4 / Libadwaita desktop interface with two modes in the header switcher (`~/Musik` is the default destination):
1. **Optical CDs (`Alt+1`):** Detect, configure (`Author` / `Album`), and rip/copy Audio CDs and MP3 data discs with one-click **Copy / Rip All** or **Start Selected**, live progress, and auto-eject.
2. **YouTube Music (`Alt+2`):** Paste a YouTube Music album or playlist URL and download tracks in `.abcde.conf`-compatible MP3 format (`<destination>/<Artist>/<Album>/<TrackNum>.<TrackTitle>.mp3`, LAME `-V 2`, embedded metadata).

### Classic CLI Mode
```bash
ruby main.rb --cli [destination]
```
Presents an interactive terminal menu to choose between:
1. **Copy / Rip CDs (Audio CD & MP3 CD)**
2. **Download YouTube Music Album (URL)**

### Keyboard Shortcuts (GUI)
- `Alt+1`: Switch to **Optical CDs** mode
- `Alt+2`: Switch to **YouTube Music** mode
- `Ctrl+Return` / `Alt+A`: **Copy / Rip All** (in Optical CDs mode) or **Download Album** (in YouTube Music mode)
- `Alt+S`: **Start Selected** checked drives (Optical CDs mode)
- `Alt+D`: **Download Album** (YouTube Music mode)
- `Alt+V`: **Paste** URL from clipboard (YouTube Music mode)
- `F5` / `Ctrl+R`: **Refresh** detected optical drives
- `Alt+B`: **Browse** for destination folder
- `Tab` / `Shift+Tab`: Navigate across all controls
- `Ctrl+Q` / `Escape`: Quit (when idle)

## Commands
`abcde -d /dev/sr0 -o mp3 -c "./.abcde.conf"`

## ToDo's

- Use cd-paranoias own progress bar as starting point for progress

## AI

All code is 100% human written execpt for abcde.conf because I couldn't be bothered to reduce the template of andrews-corner to options regarding mp3 by hand :)
