require "bundler/setup"

require_relative 'lib/usb_accessor'
require_relative 'lib/gui_app'

class Main
  attr_reader :destination, :cli_mode, :self_test

  def initialize(args = ARGV)
    parsed_args = args.dup
    @cli_mode = !parsed_args.delete("--cli").nil?
    @self_test = !parsed_args.delete("--self-test").nil?
    @destination = parsed_args[0] || "~/Musik"

    if @cli_mode
      @devices = UsbAccessor.list_drives
      @drives = UsbAccessor.get_mountpoints(@devices) # {source: {mountpoint:, type:}}
    end
  end
  
  def start
    if @cli_mode
      @drives = input_folder_names
      
      puts @drives
      UsbAccessor.copy_drives(drives: @drives, destination: @destination)
    else
      GuiApp.new(destination: @destination, self_test: @self_test).start
    end
  end

  private

  def input_folder_names
    @drives.map do |drive, attrs|
      puts("Do you want do copy the #{attrs[:type]} disk mounted in #{attrs[:mountpoint]} (y/n)?")
      copy_input = $stdin.gets.to_s.chomp

      if copy_input == "y"
        puts("Enter the name of the author, leave blank or type 'y' to auto generate:")
        author_input = $stdin.gets.to_s.chomp
        attrs[:author] = ["", "y"].include?(author_input) ? "Unknown" : author_input

        puts("Enter a name for the media, leave blank or type 'y' to auto generate:")
        name_input = $stdin.gets.to_s.chomp

        attrs[:name] = ["", "y"].include?(name_input) ? nil : name_input

        [drive, attrs]
      end
    end.compact.to_h
  end
end

Main.new.start if __FILE__ == $PROGRAM_NAME
