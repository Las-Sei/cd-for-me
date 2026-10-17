require_relative 'system_runner'

module UsbAccessor
  extend self

  def list_drives
    devices = SystemRunner.run("ls", "/dev/sr*").split("\n")

    devices.map {_1.split("/").last}
  end

  def get_data_mountpoints(drives)
    mounts_raw = SystemRunner.run("lsblk -o NAME,MOUNTPOINTS | grep", *drives).split("\n")
    
    drive_mounts = mounts_raw.map {_1.split.append("").take(2)}.to_h
    drive_mounts.select! { |drive, mount| mount != "" }
    drive_mounts.transform_values! { |mount| {mountpoint: mount, type: :data} }
  end

  def get_audio_mountpoints(drives)
    mounts_raw = SystemRunner.run("gio mount -l | grep -E '#{ [*drives].join("|")}'").split("\n")

    audio_mounts = mounts_raw.map {_1.split("->").last.strip}.uniq

    audio_mounts = audio_mounts.map {|mount| [drives.find {mount.include?(_1)}, { mountpoint: mount, type: :audio }]}.to_h
  end
  
  def get_mountpoints(drives)
    get_data_mountpoints(drives).merge(get_audio_mountpoints(drives))
  end
end