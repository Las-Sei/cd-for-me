require "bundler/setup"

require_relative 'lib/usb_accessor'

class Main
  def initialize
    @drivenames = UsbAccessor.list_drives
    @mountpoints = UsbAccessor.get_mountpoints(@drivenames)
  end
  
  def start
    UsbAccessor.copy_drives(@mountpoints)

    puts @mountpoints
  end
end

Main.new.start