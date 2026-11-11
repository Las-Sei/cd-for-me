# frozen_string_literal: true

require "json"
require "open3"
require "pathname"
require "time"

require_relative "usb_accessor"
require_relative "yt_music_downloader"
require_relative "system_runner"

class GuiApp
  PYTHON_GTK_SCRIPT_PATH = File.expand_path("gtk_gui.py", __dir__)

  attr_reader :destination, :self_test

  def initialize(destination: "~/Musik", self_test: false, accessor: UsbAccessor, downloader: YtMusicDownloader)
    @destination = destination || "~/Musik"
    @self_test = self_test
    @accessor = accessor
    @downloader = downloader
    @ipc_mutex = Mutex.new
    @worker_thread = nil
    @self_test_passed = false
  end

  def detect_drives
    devices = @accessor.list_drives
    mounts = @accessor.get_mountpoints(devices)

    mounts.each_with_object({}) do |(drive_key, attrs), result|
      result[drive_key.to_s] = {
        "drive" => (attrs[:drive] || "/dev/#{drive_key}").to_s,
        "type" => (attrs[:type] || :audio).to_s,
        "mountpoint" => (attrs[:mountpoint] || "cdda://#{drive_key}/").to_s
      }
    end
  end

  def self.prepare_drives_payload(raw_drives, copy_all: false)
    return {} unless raw_drives.is_a?(Hash)

    raw_drives.each_with_object({}) do |(drive_key, info), result|
      next unless info.is_a?(Hash)

      included = copy_all ? true : info.fetch("included", true)
      next unless included

      raw_author = info["author"].to_s.strip
      author = ["", "y"].include?(raw_author) ? "Unknown" : raw_author

      raw_name = info["name"].to_s.strip
      name = ["", "y"].include?(raw_name) ? nil : raw_name

      type_str = info["type"].to_s.strip
      type_sym = type_str.empty? ? :audio : type_str.to_sym

      result[drive_key.to_s] = {
        drive: (info["drive"] || "/dev/#{drive_key}").to_s,
        type: type_sym,
        mountpoint: info["mountpoint"].to_s,
        author: author,
        name: name
      }
    end
  end

  def self.parse_progress(line)
    text = line.to_s.split("\r").last.to_s.strip
    return nil if text.empty?

    # yt-dlp playlist item progress: "[download] Downloading item 3 of 12"
    if (m = text.match(/\[download\]\s+Downloading\s+(?:item|video)\s+(\d+)\s+of\s+(\d+)/i))
      current = m[1].to_f
      total = [m[2].to_f, 1.0].max
      return {
        fraction: ((current - 1.0) / total).clamp(0.0, 1.0),
        status: "Downloading track #{m[1]} of #{m[2]}"
      }
    # yt-dlp / rsync percentage: "[download]  45.2% of ..." or "45%"
    elsif (m = text.match(/(\d{1,3}(?:\.\d+)?)%/))
      pct = m[1].to_f / 100.0
      return {
        fraction: pct.clamp(0.0, 1.0),
        status: text
      }
    # yt-dlp post-processing lines
    elsif (m = text.match(/\[ExtractAudio\]\s+Destination:\s+(.+)/i))
      return {
        fraction: nil,
        status: "Converting to MP3: #{File.basename(m[1].strip)}"
      }
    elsif (m = text.match(/\[Metadata\]\s+Adding metadata to\s+"?([^"]+)"?/i))
      return {
        fraction: nil,
        status: "Embedding metadata: #{File.basename(m[1].strip)}"
      }
    # abcde track encoding/tagging/reading patterns: "Encoding track 03 of 12" or "Grabbing track 02..."
    elsif (m = text.match(/(?:Encoding|Tagging|Reading|Grabbing)\s+track\s+(\d+)\s+of\s+(\d+)/i))
      current = m[1].to_f
      total = [m[2].to_f, 1.0].max
      return {
        fraction: (current / total).clamp(0.0, 1.0),
        status: text
      }
    elsif (m = text.match(/Grabbing\s+track\s+(\d+)\s*:\s*(.+)/i))
      return {
        fraction: nil,
        status: "Ripping track #{m[1]}: #{m[2]}"
      }
    elsif (m = text.match(/PROGRESS\s*==\s*\[([#*|+>\-. ]+)\|\s*(\d+)/))
      bar = m[1]
      sector = m[2]
      filled = bar.rstrip.length.to_f
      total = [bar.length.to_f, 1.0].max
      return {
        fraction: (filled / total).clamp(0.0, 1.0),
        status: "cdparanoia sector #{sector}"
      }
    elsif text.end_with?(".mp3") || text.start_with?("sending incremental")
      return {
        fraction: nil,
        status: "Copying: #{text}"
      }
    end

    { fraction: nil, status: nil }
  end

  def handle_ipc_command(cmd, &emit)
    action = cmd["action"].to_s

    case action
    when "refresh_drives"
      drives = detect_drives
      emit.call({
        "type" => "drives_list",
        "drives" => drives
      })
    when "start_copy", "copy_all"
      copy_all = (action == "copy_all") || (cmd["mode"] == "copy_all")
      dest = cmd["destination"].to_s.strip
      dest = @destination if dest.empty?

      raw_drives = cmd["drives"]
      if copy_all && (raw_drives.nil? || raw_drives.empty?)
        raw_drives = detect_drives
      end

      prepared = self.class.prepare_drives_payload(raw_drives || {}, copy_all: copy_all)

      if prepared.empty?
        emit.call({
          "type" => "job_finished",
          "success" => false,
          "message" => "No drives selected or detected to copy."
        })
        return
      end

      if cmd["sync"]
        execute_copy_job(prepared, dest, &emit)
      else
        @worker_thread = Thread.new do
          execute_copy_job(prepared, dest, &emit)
        end
      end
    when "start_yt_download"
      url = cmd["url"].to_s.strip
      dest = cmd["destination"].to_s.strip
      dest = @destination if dest.empty?

      unless @downloader.valid_url?(url)
        emit.call({
          "type" => "job_finished",
          "success" => false,
          "message" => "Invalid URL: Please enter a valid http:// or https:// YouTube Music URL."
        })
        return
      end

      if cmd["sync"]
        execute_yt_download_job(url, dest, &emit)
      else
        @worker_thread = Thread.new do
          execute_yt_download_job(url, dest, &emit)
        end
      end
    when "self_test_complete"
      @self_test_passed = (cmd["status"] == "ok")
      emit.call({ "type" => "ack_self_test" })
    end
  end

  def start
    py_args = ["--destination", @destination.to_s]
    py_args << "--self-test" if @self_test

    env = { "GSK_RENDERER" => ENV["GSK_RENDERER"] || "cairo" }

    Open3.popen2(env, "python3", "-u", PYTHON_GTK_SCRIPT_PATH, *py_args) do |stdin, stdout, wait_thr|
      send_json = lambda do |payload|
        @ipc_mutex.synchronize do
          unless stdin.closed?
            stdin.puts(JSON.generate(payload))
            stdin.flush
          end
        end
      rescue Errno::EPIPE, IOError
        # UI closed
      end

      stdout.each_line do |line|
        line = line.strip
        next if line.empty?

        begin
          cmd = JSON.parse(line)
        rescue JSON::ParserError
          next
        end

        handle_ipc_command(cmd, &send_json)
      end

      @worker_thread&.join(2)
      status = wait_thr.value
      return @self_test ? (@self_test_passed && status.success?) : status.success?
    end
  end

  private

  def execute_copy_job(prepared_drives, dest, &emit)
    total = prepared_drives.size
    index = 0
    had_error = false

    emit.call({
      "type" => "job_started",
      "total_drives" => total,
      "destination" => dest,
      "message" => "Starting processing of #{total} drive(s)..."
    })

    @accessor.copy_drives(drives: prepared_drives, destination: dest) do |ev|
      event_type = ev[:event].to_s
      drive_key = ev[:drive].to_s
      msg = ev[:message].to_s

      case ev[:event]
      when :drive_start
        index += 1
        emit.call({
          "type" => "progress",
          "event" => "drive_start",
          "drive" => drive_key,
          "drive_index" => index,
          "total_drives" => total,
          "target_dir" => ev[:target_dir].to_s,
          "fraction" => ((index - 1).to_f / [total, 1].max),
          "message" => msg
        })
      when :log
        parsed = self.class.parse_progress(msg)
        emit.call({
          "type" => "progress",
          "event" => "log",
          "drive" => drive_key,
          "drive_index" => index,
          "total_drives" => total,
          "fraction" => parsed ? parsed[:fraction] : nil,
          "status_text" => parsed ? parsed[:status] : nil,
          "message" => msg
        })
      when :drive_done
        emit.call({
          "type" => "progress",
          "event" => "drive_done",
          "drive" => drive_key,
          "drive_index" => index,
          "total_drives" => total,
          "target_dir" => ev[:target_dir].to_s,
          "fraction" => (index.to_f / [total, 1].max),
          "message" => msg
        })
      when :error
        had_error = true
        emit.call({
          "type" => "progress",
          "event" => "error",
          "drive" => drive_key,
          "drive_index" => index,
          "total_drives" => total,
          "target_dir" => ev[:target_dir].to_s,
          "message" => msg
        })
      else
        emit.call({
          "type" => "progress",
          "event" => event_type,
          "drive" => drive_key,
          "message" => msg
        })
      end
    end

    emit.call({
      "type" => "job_finished",
      "success" => !had_error,
      "message" => had_error ? "Completed with errors." : "All selected drives copied/ripped and ejected."
    })

    emit.call({
      "type" => "drives_list",
      "drives" => detect_drives
    })
  rescue StandardError => e
    emit.call({
      "type" => "job_finished",
      "success" => false,
      "message" => "Error: #{e.message}"
    })
  end

  def execute_yt_download_job(url, dest, &emit)
    emit.call({
      "type" => "job_started",
      "total_drives" => 1,
      "destination" => dest,
      "message" => "Starting YouTube Music download from #{url}..."
    })

    success = @downloader.download(url: url, destination: dest) do |ev|
      msg = ev[:message].to_s

      case ev[:event]
      when :start
        emit.call({
          "type" => "progress",
          "event" => "drive_start",
          "drive" => "YouTube Music",
          "drive_index" => 1,
          "total_drives" => 1,
          "target_dir" => ev[:destination].to_s,
          "fraction" => 0.0,
          "message" => msg
        })
      when :log
        parsed = self.class.parse_progress(msg)
        emit.call({
          "type" => "progress",
          "event" => "log",
          "drive" => "YouTube Music",
          "drive_index" => 1,
          "total_drives" => 1,
          "fraction" => parsed ? parsed[:fraction] : nil,
          "status_text" => parsed ? parsed[:status] : nil,
          "message" => msg
        })
      when :done
        emit.call({
          "type" => "progress",
          "event" => "drive_done",
          "drive" => "YouTube Music",
          "drive_index" => 1,
          "total_drives" => 1,
          "target_dir" => ev[:destination].to_s,
          "fraction" => 1.0,
          "message" => msg
        })
      when :error
        emit.call({
          "type" => "progress",
          "event" => "error",
          "drive" => "YouTube Music",
          "drive_index" => 1,
          "total_drives" => 1,
          "target_dir" => ev[:destination].to_s,
          "message" => msg
        })
      end
    end

    expanded_dest = Pathname.new(dest).expand_path
    emit.call({
      "type" => "job_finished",
      "success" => !!success,
      "message" => success ? "YouTube Music album downloaded to #{expanded_dest}." : "YouTube Music download failed."
    })
  rescue StandardError => e
    emit.call({
      "type" => "job_finished",
      "success" => false,
      "message" => "Error: #{e.message}"
    })
  end
end
