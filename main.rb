require "bundler/setup"

require_relative 'lib/usb_accessor'

class Main
  def initialize
    @devices = UsbAccessor.list_drives
    @drives = UsbAccessor.get_mountpoints(@devices) # {source: {mountpoint:, type:}}
    @destination = ARGV[0] || "~/Musik"
  end
  
  def start
    @drives = input_folder_names
    
    puts @drives
    UsbAccessor.copy_drives(drives: @drives, destination: @destination)

  end

  private

  def input_folder_names
    @drives.map do |drive, attrs|
      puts("Do you want do copy the #{attrs[:type]} disk mounted in #{attrs[:mountpoint]} (y/n)?")
      copy_input = gets.chomp

      if copy_input == "y"
        puts("Enter the name of the author, leave blank or type 'y' to auto generate:")
        author_input = gets.chomp
        attrs[:author] = ["", "y"].include?(author_input) ? "Unknown" : author_input

        puts("Enter a name for the media, leave blank or type 'y' to auto generate:")
        name_input = gets.chomp

        attrs[:name] = ["", "y"].include?(name_input) ? nil : name_input

        [drive, attrs]
      end
    end.compact.to_h
  end
end

Main.new.start