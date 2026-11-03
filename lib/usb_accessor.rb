require "pathname"
require "time"

require_relative 'system_runner'

module UsbAccessor
  extend self

  def list_drives
    output = SystemRunner.run("ls /dev/sr*").to_s.strip
    return {} if output.empty?

    devices = output.split("\n").map(&:strip).reject(&:empty?)
    devices.reject! { |device| device.include?("cannot access") || device.include?("No such file") }

    devices.map { |device| [File.basename(device), { path: device }] }.to_h
  end

  def get_mountpoints(devices)
    return {} if devices.nil? || devices.empty?

    get_data_mountpoints(devices).merge(get_audio_mountpoints(devices))
  end

  def copy_drives(drives:, destination:)
    return if drives.nil? || drives.empty?

    drives.each do |drive, attrs|
      name = attrs[:name] ||= Time.now.strftime("%H:%M:%S_%m:%d:%Y")

      target_dir = Pathname.new(destination)
        .join(attrs[:author])
        .join(name)
        .expand_path
      target_dir.dirname.mkpath
      target_dir.mkpath
      attrs[:target_dir] = target_dir

      if attrs.fetch(:type) == :mp3
        SystemRunner.run("rsync -av", attrs[:mountpoint] + "/", target_dir)
      elsif attrs.fetch(:type) == :audio
        SystemRunner.run("OUTPUTDIR='#{target_dir}'","abcde -d", attrs[:drive],"-o mp3 -c './.abcde.conf'")
      end

      SystemRunner.run("eject", attrs[:drive])

    end
  end

  private

  def edit_metadata
    
  end

  def get_data_mountpoints(devices)
    return {} if devices.nil? || devices.empty?

    drives = devices.keys

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
      
      {drive: devices[mount][:path], mountpoint: mount, type:}
    end

    drive_mounts
  end

  def get_audio_mountpoints(devices)
    return {} if devices.nil? || devices.empty?

    drives = devices.keys

    mounts_raw = SystemRunner.run("gio mount -l | grep -E '#{ [*drives].join("|")}'").split("\n")
    # findet für audio cd zeilen wie: Mount(0): Audio-CD -> cdda://sr0/

    audio_mounts = mounts_raw.map {_1.split("cdda:").last.delete("/").strip}.uniq

    audio_mounts = audio_mounts.map do |mount|
      mounted_drive = drives.find {mount == _1}
      next unless mounted_drive && devices[mount]

      [mounted_drive, { drive: devices[mount][:path], type: :audio }]
    end.compact.to_h
  end
end
