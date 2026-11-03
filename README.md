# cd-for-me

## Requirements
- abcde `sudo apt install abcde`
- flac `sudo apt install flac`
- yt-dlp `sudo apt install yt-dlp`
- ffmpeg `sudo apt install ffmpeg`

### abcde
- eyeD3 `sudo apt install eyed3`
- MP3 encoder `sudo apt install lame`

### YouTube Music Downloader
- `yt-dlp` and `ffmpeg` for extracting and tagging MP3 audio (`-V 2` VBR quality) from YouTube Music album/playlist URLs.

## Usage

Run the interactive CLI (defaults to `~/Musik` unless a destination path is passed):

```bash
ruby main.rb [destination]
```

At startup, choose between:
1. **Copy / Rip CDs (Audio CD & MP3 CD):** Detects optical drives (`/dev/sr*`), prompts for artist/album names, rips audio CDs via `abcde` or copies MP3 CDs via `rsync`, and ejects the disc.
2. **Download YouTube Music Album (URL):** Prompts for a YouTube Music album or playlist URL and downloads tracks as MP3 (`-V 2`) into `<destination>/<Artist>/<Album>/<TrackNum>.<TrackTitle>.mp3`, matching the `.abcde.conf` naming and sanitization conventions.

## Commands
`abcde -d /dev/sr0 -o mp3 -c "./.abcde.conf"`

## ToDo's

- Use cd-paranoias own progress bar as starting point for progress

## AI

All code is 100% human written execpt for abcde.conf because I couldn't be bothered to reduce the template of andrews-corner to options regarding mp3 by hand :)
