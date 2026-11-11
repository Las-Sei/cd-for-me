require "pathname"
require "shellwords"
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

  def copy_drives(drives:, destination:, &on_progress)
    return if drives.nil? || drives.empty?

    drives.each do |drive, attrs|
      author = attrs[:author].to_s.strip
      author = "Unknown" if author.empty?
      attrs[:author] = author

      raw_name = attrs[:name].to_s.strip
      name = raw_name.empty? ? Time.now.strftime("%H:%M:%S_%m:%d:%Y") : raw_name
      attrs[:name] = name

      target_dir = Pathname.new(destination)
        .join(author)
        .join(name)
        .expand_path
      target_dir.dirname.mkpath
      target_dir.mkpath
      attrs[:target_dir] = target_dir

      on_progress&.call({
        event: :drive_start,
        drive: drive,
        attrs: attrs,
        target_dir: target_dir.to_s,
        message: "Starting #{attrs[:type]} drive #{attrs[:drive] || drive} -> #{target_dir}"
      })

      success = true
      if attrs.fetch(:type) == :mp3
        source_dir = Shellwords.escape("#{attrs[:mountpoint]}/")
        escaped_target_dir = Shellwords.escape(target_dir.to_s)
        if block_given?
          success = SystemRunner.run_stream("rsync -av", source_dir, escaped_target_dir) do |line|
            on_progress.call({ event: :log, drive: drive, attrs: attrs, message: line })
          end
        else
          SystemRunner.run("rsync -av", source_dir, escaped_target_dir)
        end
      elsif attrs.fetch(:type) == :audio
        escaped_target_dir = Shellwords.escape(target_dir.to_s)
        escaped_drive = Shellwords.escape(attrs[:drive].to_s)
        if block_given?
          success = SystemRunner.run_stream("OUTPUTDIR=#{escaped_target_dir}", "abcde -d", escaped_drive, "-o mp3 -c './.abcde.conf'") do |line|
            on_progress.call({ event: :log, drive: drive, attrs: attrs, message: line })
          end
        else
          SystemRunner.run("OUTPUTDIR=#{escaped_target_dir}", "abcde -d", escaped_drive, "-o mp3 -c './.abcde.conf'")
        end
      end

      escaped_drive = Shellwords.escape(attrs[:drive].to_s)
      if block_given?
        SystemRunner.run_stream("eject", escaped_drive) do |line|
          on_progress.call({ event: :log, drive: drive, attrs: attrs, message: line })
        end
        if success
          on_progress.call({
            event: :drive_done,
            drive: drive,
            attrs: attrs,
            target_dir: target_dir.to_s,
            message: "Finished #{attrs[:drive] || drive}"
          })
        else
          on_progress.call({
            event: :error,
            drive: drive,
            attrs: attrs,
            target_dir: target_dir.to_s,
            message: "Error processing #{attrs[:drive] || drive}"
          })
        end
      else
        SystemRunner.run("eject", escaped_drive)
      end

    end
  end

  private

  def edit_metadata
    
  end

  def get_data_mountpoints(devices)
    return {} if devices.nil? || devices.empty?

    drives = devices.keys
    return {} if drives.empty?

    mounts_raw = SystemRunner.run("lsblk -o NAME,MOUNTPOINTS | grep -E '#{[*drives].join("|")}'").split("\n")
    # Audio CDs haben keinen Mountpoint
    
    drive_mounts = mounts_raw.map { _1.strip.split(/\s+/, 2).append("").take(2) }.to_h
    drive_mounts.select! { |drive, mount| mount != "" }
    drive_mounts.each_with_object({}) do |(drive, mount), result|
      filenames = SystemRunner.run("ls -l", Shellwords.escape(mount), "| sed '1d'").split("\n")
      # |sed '1d' verhindet das die erste zeile angezeigt wird, die zeigt die summe des belegten speichers
      # -r-------- 1 lasse lasse  766498 Apr 25  2024 9783844551860_054_054.mp3
      types = filenames.reject(&:empty?).filter_map { _1.split.last&.split(".")&.last&.downcase }.uniq

      type = types.length == 1 && types.first == "mp3" ? :mp3 : :data
      clean_drive = drive.sub(/\A[^a-zA-Z0-9]+/, "")
      drive_key = clean_drive.empty? ? drive : clean_drive
      drive_path = devices.dig(drive, :path) || devices.dig(drive_key, :path) || devices.dig(mount, :path) || "/dev/#{drive_key}"

      result[drive_key] = {drive: drive_path, mountpoint: mount, type:}
    end
  end

  def get_audio_mountpoints(devices)
    return {} if devices.nil? || devices.empty?

    drives = devices.keys
    return {} if drives.empty?

    mounts_raw = SystemRunner.run("gio mount -l | grep -E '#{ [*drives].join("|")}'").split("\n")
    # findet für audio cd zeilen wie: Mount(0): Audio-CD -> cdda://sr0/

    audio_mounts = mounts_raw.filter_map do |line|
      next unless line.include?("cdda:")

      line.split("cdda:").last.delete("/").strip
    end.uniq

    audio_mounts.each_with_object({}) do |mount, result|
      mounted_drive = drives.find {mount == _1}
      next unless mounted_drive && devices[mount]

      result[mounted_drive] = { drive: devices[mount][:path], type: :audio }
    end
  end
end
