require "pathname"
require "uri"

require_relative "system_runner"

module YtMusicDownloader
  extend self

  METADATA_FIELDS = "album_artist,artist,uploader,album,playlist_title,title"
  LEADING_DOTS_REGEX = '^\\.+'
  ILLEGAL_CHARS_REGEX = '[:><|*/"\'?\x00-\x1f\x7f]+'

  def valid_url?(url)
    return false if url.nil?

    cleaned = url.to_s.strip
    return false if cleaned.empty?

    uri = URI.parse(cleaned)
    (uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)) && !uri.host.nil? && !uri.host.empty?
  rescue URI::InvalidURIError
    false
  end

  def validate_url!(url)
    unless valid_url?(url)
      raise ArgumentError, "Invalid URL: #{url.inspect}. Must be a valid http:// or https:// URL."
    end

    url.to_s.strip
  end

  # Matches mungefilename() in .abcde.conf:
  # echo "$@" | sed -e 's/^\.*//' | tr -d ":><|*/\"'?[:cntrl:]"
  def sanitize_filename(name)
    name.to_s.sub(/\A\.+/, "").gsub(/[:><|*\/"'?\x00-\x1f\x7f]/, "")
  end
  alias_method :mungefilename, :sanitize_filename

  def output_template(destination)
    base_dir = Pathname.new(destination).expand_path
    "#{base_dir}/%(album_artist,artist,uploader|Unknown)s/%(album,playlist_title|Unknown Album)s/%(playlist_index,track_number|01)02d.%(title)s.%(ext)s"
  end

  def build_command(url:, destination:)
    clean_url = validate_url!(url)

    [
      "yt-dlp",
      "-x",
      "--audio-format", "mp3",
      "--audio-quality", "2",
      "--embed-metadata",
      "--parse-metadata", "playlist_index:%(track_number)s",
      "--replace-in-metadata", METADATA_FIELDS, LEADING_DOTS_REGEX, "",
      "--replace-in-metadata", METADATA_FIELDS, ILLEGAL_CHARS_REGEX, "",
      "-o", output_template(destination),
      clean_url
    ]
  end

  def download(url:, destination:, &on_progress)
    clean_url = validate_url!(url)
    base_dir = Pathname.new(destination).expand_path
    base_dir.mkpath

    cmd = build_command(url: clean_url, destination: base_dir.to_s)

    if block_given?
      on_progress.call({
        event: :start,
        url: clean_url,
        destination: base_dir.to_s,
        message: "Starting YouTube Music download: #{clean_url} -> #{base_dir}"
      })

      success = SystemRunner.run_live(*cmd) do |line|
        on_progress.call({
          event: :log,
          url: clean_url,
          destination: base_dir.to_s,
          message: line
        })
      end

      if success
        on_progress.call({
          event: :done,
          url: clean_url,
          destination: base_dir.to_s,
          message: "Download finished. Saved to #{base_dir}"
        })
      else
        on_progress.call({
          event: :error,
          url: clean_url,
          destination: base_dir.to_s,
          message: "Download failed for #{clean_url}"
        })
      end

      success
    else
      success = SystemRunner.run_live(*cmd)

      if success
        puts("Download finished. Saved to #{base_dir}")
      else
        puts("Download failed for #{clean_url}")
      end

      success
    end
  end
end
