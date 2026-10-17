require_relative 'system_runner'

module UsbAccessor
  extend self

  def list_drives
    devices = SystemRunner.run("ls", "/dev/sr*").split("\n")

    devices.map {_1.split("/").last}
  end

  def get_mountpoints(drivenames)
    get_data_mountpoints(drivenames).merge(get_audio_mountpoints(drivenames))
  end

  def copy_drives(drives)
    
  end

  private

  def get_data_mountpoints(drives)
    mounts_raw = SystemRunner.run("lsblk -o NAME,MOUNTPOINTS | grep", *drives).split("\n")
    # Audio CDs haben keinen Mountpoint
    
    drive_mounts = mounts_raw.map {_1.split.append("").take(2)}.to_h
    drive_mounts.select! { |drive, mount| mount != "" }
    drive_mounts.transform_values! do |mount| 
      filenames = SystemRunner.run("ls -l", mount, "| sed '1d'").split("\n")
      # |sed '1d' verhindet das die erste zeile angezeigt wird, die zeigt die summe des belegten speichers
      # -r-------- 1 lasse lasse  766498 Apr 25  2024 9783844551860_054_054.mp3
      types = filenames.map {_1.split.last.split(".").last}.uniq

      type = types.length == 1 && types.first == "mp3" ? :mp3 : :data
      
      {mountpoint: mount, type:}
    end

    drive_mounts
  end

  def get_audio_mountpoints(drives)
    mounts_raw = SystemRunner.run("gio mount -l | grep -E '#{ [*drives].join("|")}'").split("\n")
    # findet für audio cd zeilen wie: Mount(0): Audio-CD -> cdda://sr0/

    audio_mounts = mounts_raw.map {_1.split("->").last.strip}.uniq

    audio_mounts = audio_mounts.map {|mount| [drives.find {mount.include?(_1)}, { mountpoint: mount, type: :audio }]}.to_h
  end
end