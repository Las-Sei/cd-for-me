require "bundler/setup"

require_relative 'lib/usb_accessor'
require_relative 'lib/yt_music_downloader'
require_relative 'lib/gui_app'

class Main
  attr_reader :destination, :devices, :drives, :cli_mode, :self_test

  def initialize(args = ARGV, destination: nil, input: nil, output: nil, cli_mode: nil)
    parsed_args = Array(args).dup
    cli_flag = !parsed_args.delete("--cli").nil?
    @self_test = !parsed_args.delete("--self-test").nil?

    @input = input
    @output = output
    @cli_mode = if !cli_mode.nil?
                  cli_mode
                else
                  cli_flag || !input.nil? || !output.nil?
                end

    @destination = destination || parsed_args[0] || "~/Musik"
    @devices = {}
    @drives = {}
  end

  def start
    if @cli_mode
      start_cli
    else
      GuiApp.new(destination: @destination, self_test: @self_test).start
    end
  end

  private

  def input_stream
    @input || $stdin
  end

  def output_stream
    @output || $stdout
  end

  def read_line
    line = input_stream.gets
    line ? line.chomp.strip : ""
  end

  def start_cli
    output_stream.puts("Select mode:")
    output_stream.puts("[1] Copy / Rip CDs (Audio CD & MP3 CD)")
    output_stream.puts("[2] Download YouTube Music Album (URL)")
    output_stream.puts("Choose (1/2, default: 1):")

    mode_input = read_line
    mode = mode_input.empty? || mode_input.downcase == "y" ? "1" : mode_input

    case mode
    when "1"
      start_cd_mode
    when "2"
      start_yt_music_mode
    else
      output_stream.puts("Invalid selection '#{mode_input}'. Defaulting to [1] Copy / Rip CDs.")
      start_cd_mode
    end
  end

  def start_cd_mode
    @devices = UsbAccessor.list_drives
    @drives = UsbAccessor.get_mountpoints(@devices) # {source: {mountpoint:, type:}}

    if @drives.empty?
      output_stream.puts("No CD drives or discs detected.")
      return
    end

    @drives = input_folder_names

    output_stream.puts(@drives)
    UsbAccessor.copy_drives(drives: @drives, destination: @destination)
  end

  def start_yt_music_mode
    output_stream.puts("Paste the YouTube Music album/playlist URL:")
    url = read_line

    YtMusicDownloader.download(url: url, destination: @destination)
  rescue ArgumentError => e
    output_stream.puts(e.message)
    false
  end

  def input_folder_names
    @drives.map do |drive, attrs|
      output_stream.puts("Do you want do copy the #{attrs[:type]} disk mounted in #{attrs[:mountpoint]} (y/n)?")
      copy_input = read_line

      if copy_input == "y"
        output_stream.puts("Enter the name of the author, leave blank or type 'y' to auto generate:")
        author_input = read_line
        attrs[:author] = ["", "y"].include?(author_input) ? "Unknown" : author_input

        output_stream.puts("Enter a name for the media, leave blank or type 'y' to auto generate:")
        name_input = read_line

        attrs[:name] = ["", "y"].include?(name_input) ? nil : name_input

        [drive, attrs]
      end
    end.compact.to_h
  end
end

Main.new.start if __FILE__ == $PROGRAM_NAME
