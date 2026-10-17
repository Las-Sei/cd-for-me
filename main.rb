require "bundler/setup"

require_relative 'lib/usb_accessor'

class Main
  def initialize
    @drives = UsbAccessor.list_drives
    @mountpoints = UsbAccessor.get_mountpoints(@drives)
  end
  
  def start
    puts @mountpoints
  end
end

Main.new.start