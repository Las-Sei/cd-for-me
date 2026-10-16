require_relative 'system_runner'

module UsbAccessor
  extend self

  def list_drives
    devices = SystemRunner.run("ls", "/dev/sr*").split("\n")

    devices.map {_1.split("/").last}
  end

  def get_mountpoints(drives)
    mounts_raw = SystemRunner.run("lsblk -o NAME,MOUNTPOINTS | grep", *drives).split("\n")
    
    mounts_raw.map {_1.split.take(2)}.to_h
  end

  
end