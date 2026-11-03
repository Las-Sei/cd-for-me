# frozen_string_literal: true

require "json"
require "open3"
require "pathname"
require "time"

require_relative "usb_accessor"
require_relative "system_runner"

class GuiApp
  attr_reader :destination, :self_test

  def initialize(destination: "~/Musik", self_test: false, accessor: UsbAccessor)
    @destination = destination || "~/Musik"
    @self_test = self_test
    @accessor = accessor
    @ipc_mutex = Mutex.new
    @worker_thread = nil
    @self_test_passed = false
  end

  def detect_drives
    devices = @accessor.list_drives
    mounts = @accessor.get_mountpoints(devices)

    mounts.each_with_object({}) do |(drive_key, attrs), result|
      result[drive_key.to_s] = {
        "drive" => (attrs[:drive] || "/dev/#{drive_key}").to_s,
        "type" => (attrs[:type] || :audio).to_s,
        "mountpoint" => (attrs[:mountpoint] || "cdda://#{drive_key}/").to_s
      }
    end
  end

  def self.prepare_drives_payload(raw_drives, copy_all: false)
    return {} unless raw_drives.is_a?(Hash)

    raw_drives.each_with_object({}) do |(drive_key, info), result|
      next unless info.is_a?(Hash)

      included = copy_all ? true : info.fetch("included", true)
      next unless included

      raw_author = info["author"].to_s.strip
      author = ["", "y"].include?(raw_author) ? "Unknown" : raw_author

      raw_name = info["name"].to_s.strip
      name = ["", "y"].include?(raw_name) ? nil : raw_name

      type_str = info["type"].to_s.strip
      type_sym = type_str.empty? ? :audio : type_str.to_sym

      result[drive_key.to_s] = {
        drive: (info["drive"] || "/dev/#{drive_key}").to_s,
        type: type_sym,
        mountpoint: info["mountpoint"].to_s,
        author: author,
        name: name
      }
    end
  end

  def self.parse_progress(line)
    text = line.to_s.split("\r").last.to_s.strip
    return nil if text.empty?

    # abcde track encoding/tagging/reading patterns: "Encoding track 03 of 12" or "Grabbing track 02..."
    if (m = text.match(/(?:Encoding|Tagging|Reading|Grabbing)\s+track\s+(\d+)\s+of\s+(\d+)/i))
      current = m[1].to_f
      total = [m[2].to_f, 1.0].max
      return {
        fraction: (current / total).clamp(0.0, 1.0),
        status: text
      }
    elsif (m = text.match(/Grabbing\s+track\s+(\d+)\s*:\s*(.+)/i))
      return {
        fraction: nil,
        status: "Ripping track #{m[1]}: #{m[2]}"
      }
    elsif (m = text.match(/PROGRESS\s*==\s*\[([#*|+>\-. ]+)\|\s*(\d+)/))
      bar = m[1]
      sector = m[2]
      filled = bar.rstrip.length.to_f
      total = [bar.length.to_f, 1.0].max
      return {
        fraction: (filled / total).clamp(0.0, 1.0),
        status: "cdparanoia sector #{sector}"
      }
    elsif (m = text.match(/(\d{1,3})%/))
      pct = m[1].to_f / 100.0
      return {
        fraction: pct.clamp(0.0, 1.0),
        status: text
      }
    elsif text.end_with?(".mp3") || text.start_with?("sending incremental")
      return {
        fraction: nil,
        status: "Copying: #{text}"
      }
    end

    { fraction: nil, status: nil }
  end

  def handle_ipc_command(cmd, &emit)
    action = cmd["action"].to_s

    case action
    when "refresh_drives"
      drives = detect_drives
      emit.call({
        "type" => "drives_list",
        "drives" => drives
      })
    when "start_copy", "copy_all"
      copy_all = (action == "copy_all") || (cmd["mode"] == "copy_all")
      dest = cmd["destination"].to_s.strip
      dest = @destination if dest.empty?

      raw_drives = cmd["drives"]
      if copy_all && (raw_drives.nil? || raw_drives.empty?)
        raw_drives = detect_drives
      end

      prepared = self.class.prepare_drives_payload(raw_drives || {}, copy_all: copy_all)

      if prepared.empty?
        emit.call({
          "type" => "job_finished",
          "success" => false,
          "message" => "No drives selected or detected to copy."
        })
        return
      end

      if cmd["sync"]
        execute_copy_job(prepared, dest, &emit)
      else
        @worker_thread = Thread.new do
          execute_copy_job(prepared, dest, &emit)
        end
      end
    when "self_test_complete"
      @self_test_passed = (cmd["status"] == "ok")
      emit.call({ "type" => "ack_self_test" })
    end
  end

  def start
    py_args = ["--destination", @destination.to_s]
    py_args << "--self-test" if @self_test

    env = { "GSK_RENDERER" => ENV["GSK_RENDERER"] || "cairo" }

    Open3.popen2(env, "python3", "-u", "-c", PYTHON_GTK_SCRIPT, *py_args) do |stdin, stdout, wait_thr|
      send_json = lambda do |payload|
        @ipc_mutex.synchronize do
          unless stdin.closed?
            stdin.puts(JSON.generate(payload))
            stdin.flush
          end
        end
      rescue Errno::EPIPE, IOError
        # UI closed
      end

      stdout.each_line do |line|
        line = line.strip
        next if line.empty?

        begin
          cmd = JSON.parse(line)
        rescue JSON::ParserError
          next
        end

        handle_ipc_command(cmd, &send_json)
      end

      @worker_thread&.join(2)
      status = wait_thr.value
      return @self_test ? (@self_test_passed && status.success?) : status.success?
    end
  end

  private

  def execute_copy_job(prepared_drives, dest, &emit)
    total = prepared_drives.size
    index = 0
    had_error = false

    emit.call({
      "type" => "job_started",
      "total_drives" => total,
      "destination" => dest,
      "message" => "Starting processing of #{total} drive(s)..."
    })

    @accessor.copy_drives(drives: prepared_drives, destination: dest) do |ev|
      event_type = ev[:event].to_s
      drive_key = ev[:drive].to_s
      msg = ev[:message].to_s

      case ev[:event]
      when :drive_start
        index += 1
        emit.call({
          "type" => "progress",
          "event" => "drive_start",
          "drive" => drive_key,
          "drive_index" => index,
          "total_drives" => total,
          "target_dir" => ev[:target_dir].to_s,
          "fraction" => ((index - 1).to_f / [total, 1].max),
          "message" => msg
        })
      when :log
        parsed = self.class.parse_progress(msg)
        emit.call({
          "type" => "progress",
          "event" => "log",
          "drive" => drive_key,
          "drive_index" => index,
          "total_drives" => total,
          "fraction" => parsed ? parsed[:fraction] : nil,
          "status_text" => parsed ? parsed[:status] : nil,
          "message" => msg
        })
      when :drive_done
        emit.call({
          "type" => "progress",
          "event" => "drive_done",
          "drive" => drive_key,
          "drive_index" => index,
          "total_drives" => total,
          "target_dir" => ev[:target_dir].to_s,
          "fraction" => (index.to_f / [total, 1].max),
          "message" => msg
        })
      when :error
        had_error = true
        emit.call({
          "type" => "progress",
          "event" => "error",
          "drive" => drive_key,
          "drive_index" => index,
          "total_drives" => total,
          "target_dir" => ev[:target_dir].to_s,
          "message" => msg
        })
      else
        emit.call({
          "type" => "progress",
          "event" => event_type,
          "drive" => drive_key,
          "message" => msg
        })
      end
    end

    emit.call({
      "type" => "job_finished",
      "success" => !had_error,
      "message" => had_error ? "Completed with errors." : "All selected drives copied/ripped and ejected."
    })

    emit.call({
      "type" => "drives_list",
      "drives" => detect_drives
    })
  rescue StandardError => e
    emit.call({
      "type" => "job_finished",
      "success" => false,
      "message" => "Error: #{e.message}"
    })
  end

  PYTHON_GTK_SCRIPT = <<~'PYTHON'
    import sys
    import os
    import json
    import threading
    import argparse

    import gi
    gi.require_version('Gtk', '4.0')
    gi.require_version('Adw', '1')
    from gi.repository import Gtk, Adw, Gio, GLib, Pango

    class CdForMeWindow(Adw.ApplicationWindow):
        def __init__(self, app, destination, self_test=False):
            super().__init__(application=app, title="CD For Me")
            self.set_default_size(760, 620)
            self.destination = destination
            self.self_test = self_test
            self.is_busy = False
            self.drive_rows = {}
            self.pulse_timer_id = None

            self._build_ui()
            self._setup_shortcuts()

        def _send_ipc(self, payload):
            try:
                sys.stdout.write(json.dumps(payload) + "\n")
                sys.stdout.flush()
            except Exception:
                pass

        def _build_ui(self):
            toolbar_view = Adw.ToolbarView()
            self.set_content(toolbar_view)

            # HeaderBar
            header = Adw.HeaderBar()
            title_widget = Adw.WindowTitle(
                title="CD For Me",
                subtitle="Audio CD & MP3 CD Ripper / Copier"
            )
            header.set_title_widget(title_widget)

            self.refresh_btn = Gtk.Button.new_with_mnemonic("_Refresh")
            self.refresh_btn.set_icon_name("view-refresh-symbolic")
            self.refresh_btn.set_tooltip_text("Refresh Optical Drives (F5 / Ctrl+R)")
            self.refresh_btn.connect("clicked", lambda *_: self.request_refresh())
            header.pack_start(self.refresh_btn)

            self.copy_all_btn = Gtk.Button.new_with_mnemonic("_Copy / Rip All")
            self.copy_all_btn.add_css_class("suggested-action")
            self.copy_all_btn.set_tooltip_text(
                "Select all drives, fill default Author/Album for blank fields, and start immediately (Ctrl+Return / Alt+A)"
            )
            self.copy_all_btn.connect("clicked", lambda *_: self.trigger_copy_all())
            header.pack_end(self.copy_all_btn)

            toolbar_view.add_top_bar(header)

            # Main scrollable area
            scrolled = Gtk.ScrolledWindow()
            scrolled.set_vexpand(True)
            scrolled.set_hexpand(True)
            scrolled.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)

            clamp = Adw.Clamp()
            clamp.set_maximum_size(700)
            clamp.set_margin_top(16)
            clamp.set_margin_bottom(16)
            clamp.set_margin_start(16)
            clamp.set_margin_end(16)
            scrolled.set_child(clamp)

            main_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=18)
            clamp.set_child(main_box)

            # Destination section
            dest_group = Adw.PreferencesGroup(
                title="Destination Folder",
                description="Target base directory (Destination / Author / Album)"
            )
            main_box.append(dest_group)

            dest_row = Adw.ActionRow(title="Output Directory")
            self.dest_entry = Gtk.Entry()
            self.dest_entry.set_text(self.destination)
            self.dest_entry.set_hexpand(True)
            self.dest_entry.set_valign(Gtk.Align.CENTER)
            self.dest_entry.set_placeholder_text("~/Musik")

            self.browse_btn = Gtk.Button.new_with_mnemonic("_Browse…")
            self.browse_btn.set_valign(Gtk.Align.CENTER)
            self.browse_btn.set_tooltip_text("Choose destination folder (Alt+B)")
            self.browse_btn.connect("clicked", self._on_browse_clicked)

            dest_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
            dest_box.set_hexpand(True)
            dest_box.append(self.dest_entry)
            dest_box.append(self.browse_btn)
            dest_row.add_suffix(dest_box)
            dest_group.add(dest_row)

            # Drives section
            self.drives_group = Adw.PreferencesGroup(
                title="Detected Optical Drives",
                description="Select drives to process and optionally enter Author and Album / Media Name."
            )
            main_box.append(self.drives_group)

            self.drives_container = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
            self.drives_group.add(self.drives_container)

            # Empty state card / StatusPage
            self.empty_status = Adw.StatusPage(
                icon_name="media-optical-symbolic",
                title="No Audio or MP3 CDs Detected",
                description="Insert an Audio CD or MP3 data disc and press Refresh (F5)."
            )
            empty_refresh_btn = Gtk.Button.new_with_mnemonic("_Refresh Drives (F5)")
            empty_refresh_btn.set_halign(Gtk.Align.CENTER)
            empty_refresh_btn.add_css_class("pill")
            empty_refresh_btn.connect("clicked", lambda *_: self.request_refresh())
            self.empty_status.set_child(empty_refresh_btn)
            self.drives_container.append(self.empty_status)

            toolbar_view.set_content(scrolled)

            # Footer Action & Progress Bar
            footer_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
            footer_box.set_margin_top(10)
            footer_box.set_margin_bottom(12)
            footer_box.set_margin_start(16)
            footer_box.set_margin_end(16)

            top_footer = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)

            self.start_selected_btn = Gtk.Button.new_with_mnemonic("_Start Selected")
            self.start_selected_btn.add_css_class("suggested-action")
            self.start_selected_btn.set_tooltip_text("Copy / Rip checked drives (Alt+S)")
            self.start_selected_btn.connect("clicked", lambda *_: self.trigger_start_selected())
            top_footer.append(self.start_selected_btn)

            self.status_label = Gtk.Label(label="Ready")
            self.status_label.set_halign(Gtk.Align.START)
            self.status_label.set_hexpand(True)
            self.status_label.set_ellipsize(Pango.EllipsizeMode.END)
            top_footer.append(self.status_label)

            footer_box.append(top_footer)

            self.progress_bar = Gtk.ProgressBar()
            self.progress_bar.set_show_text(True)
            self.progress_bar.set_text("Idle")
            self.progress_bar.set_fraction(0.0)
            footer_box.append(self.progress_bar)

            # Expandable Live Log
            self.log_expander = Gtk.Expander(label="Live Command Log (abcde / cdparanoia / rsync)")
            log_scroll = Gtk.ScrolledWindow()
            log_scroll.set_min_content_height(150)
            log_scroll.set_vexpand(False)

            self.log_view = Gtk.TextView()
            self.log_view.set_editable(False)
            self.log_view.set_cursor_visible(False)
            self.log_view.set_monospace(True)
            self.log_view.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
            self.log_buffer = self.log_view.get_buffer()
            log_scroll.set_child(self.log_view)
            self.log_expander.set_child(log_scroll)
            footer_box.append(self.log_expander)

            toolbar_view.add_bottom_bar(footer_box)

        def _setup_shortcuts(self):
            controller = Gtk.ShortcutController()
            controller.set_scope(Gtk.ShortcutScope.MANAGED)

            # F5 / Ctrl+R -> Refresh
            controller.add_shortcut(Gtk.Shortcut.new(
                Gtk.ShortcutTrigger.parse_string("F5|<Control>r"),
                Gtk.CallbackAction.new(lambda *_: self._shortcut_refresh())
            ))

            # Ctrl+Return / Ctrl+KP_Enter / Alt+a -> Copy / Rip All
            controller.add_shortcut(Gtk.Shortcut.new(
                Gtk.ShortcutTrigger.parse_string("<Control>Return|<Control>KP_Enter|<Alt>a"),
                Gtk.CallbackAction.new(lambda *_: self._shortcut_copy_all())
            ))

            # Alt+s -> Start Selected
            controller.add_shortcut(Gtk.Shortcut.new(
                Gtk.ShortcutTrigger.parse_string("<Alt>s"),
                Gtk.CallbackAction.new(lambda *_: self._shortcut_start_selected())
            ))

            # Ctrl+q / Escape -> Quit when idle
            controller.add_shortcut(Gtk.Shortcut.new(
                Gtk.ShortcutTrigger.parse_string("<Control>q|Escape"),
                Gtk.CallbackAction.new(lambda *_: self._shortcut_quit())
            ))

            self.add_controller(controller)

        def _shortcut_refresh(self):
            if not self.is_busy:
                self.request_refresh()
            return True

        def _shortcut_copy_all(self):
            if not self.is_busy:
                self.trigger_copy_all()
            return True

        def _shortcut_start_selected(self):
            if not self.is_busy:
                self.trigger_start_selected()
            return True

        def _shortcut_quit(self):
            if not self.is_busy:
                self.get_application().quit()
            return True

        def _on_browse_clicked(self, _btn):
            if hasattr(Gtk, "FileDialog"):
                dialog = Gtk.FileDialog(title="Select Destination Folder")
                dialog.select_folder(self, None, self._on_folder_selected)

        def _on_folder_selected(self, dialog, result):
            try:
                folder = dialog.select_folder_finish(result)
                if folder:
                    path = folder.get_path()
                    if path:
                        self.dest_entry.set_text(path)
            except Exception:
                pass

        def request_refresh(self):
            if self.is_busy:
                return
            self.status_label.set_text("Scanning optical drives...")
            self._send_ipc({"action": "refresh_drives"})

        def populate_drives(self, drives_dict):
            # Remove existing rows
            child = self.drives_container.get_first_child()
            while child is not None:
                next_child = child.get_next_sibling()
                self.drives_container.remove(child)
                child = next_child

            self.drive_rows.clear()

            if not drives_dict:
                self.drives_container.append(self.empty_status)
                self.start_selected_btn.set_sensitive(False)
                self.copy_all_btn.set_sensitive(False)
                if not self.is_busy:
                    self.status_label.set_text("No optical discs detected.")
                return

            self.start_selected_btn.set_sensitive(not self.is_busy)
            self.copy_all_btn.set_sensitive(not self.is_busy)

            for drive_key, info in drives_dict.items():
                drive_path = info.get("drive") or f"/dev/{drive_key}"
                drive_type = info.get("type") or "audio"
                mountpoint = info.get("mountpoint") or f"cdda://{drive_key}/"

                badge_text = "Audio CD" if drive_type == "audio" else ("MP3 CD" if drive_type == "mp3" else "Data CD")

                card = Gtk.Frame()
                card_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
                card_box.set_margin_top(12)
                card_box.set_margin_bottom(12)
                card_box.set_margin_start(12)
                card_box.set_margin_end(12)
                card.set_child(card_box)

                # Header row for drive card
                header_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)

                include_check = Gtk.CheckButton(label=f"Include {drive_path}")
                include_check.set_active(True)
                include_check.set_tooltip_text(f"Include {drive_path} when copying/ripping")
                header_row.append(include_check)

                type_badge = Gtk.Label(label=badge_text)
                type_badge.add_css_class("accent")
                type_badge.add_css_class("heading")
                header_row.append(type_badge)

                mount_label = Gtk.Label(label=f"({mountpoint})")
                mount_label.add_css_class("dim-label")
                mount_label.set_hexpand(True)
                mount_label.set_halign(Gtk.Align.START)
                mount_label.set_ellipsize(Pango.EllipsizeMode.MIDDLE)
                header_row.append(mount_label)

                card_box.append(header_row)

                # Metadata inputs grid
                grid = Gtk.Grid(column_spacing=12, row_spacing=8)

                author_lbl = Gtk.Label(label="Author:")
                author_lbl.set_halign(Gtk.Align.END)
                author_entry = Gtk.Entry()
                author_entry.set_hexpand(True)
                author_entry.set_placeholder_text("Unknown (default)")
                grid.attach(author_lbl, 0, 0, 1, 1)
                grid.attach(author_entry, 1, 0, 1, 1)

                name_lbl = Gtk.Label(label="Album / Media Name:")
                name_lbl.set_halign(Gtk.Align.END)
                name_entry = Gtk.Entry()
                name_entry.set_hexpand(True)
                name_entry.set_placeholder_text("Auto timestamp (default)")
                grid.attach(name_lbl, 0, 1, 1, 1)
                grid.attach(name_entry, 1, 1, 1, 1)

                card_box.append(grid)
                self.drives_container.append(card)

                self.drive_rows[drive_key] = {
                    "drive": drive_path,
                    "type": drive_type,
                    "mountpoint": mountpoint,
                    "check": include_check,
                    "author_entry": author_entry,
                    "name_entry": name_entry,
                }

            if not self.is_busy:
                self.status_label.set_text(f"Detected {len(self.drive_rows)} disc(s). Ready.")

        def collect_drives_payload(self, select_all=False):
            payload = {}
            for drive_key, widgets in self.drive_rows.items():
                if select_all:
                    widgets["check"].set_active(True)
                    if not widgets["author_entry"].get_text().strip():
                        widgets["author_entry"].set_text("Unknown")

                payload[drive_key] = {
                    "drive": widgets["drive"],
                    "type": widgets["type"],
                    "mountpoint": widgets["mountpoint"],
                    "included": True if select_all else widgets["check"].get_active(),
                    "author": widgets["author_entry"].get_text().strip(),
                    "name": widgets["name_entry"].get_text().strip(),
                }
            return payload

        def trigger_copy_all(self):
            if self.is_busy or not self.drive_rows:
                return
            drives_payload = self.collect_drives_payload(select_all=True)
            dest = self.dest_entry.get_text().strip() or self.destination
            self._set_busy_state(True, "Starting Copy / Rip All...")
            self._send_ipc({
                "action": "copy_all",
                "mode": "copy_all",
                "destination": dest,
                "drives": drives_payload,
            })

        def trigger_start_selected(self):
            if self.is_busy or not self.drive_rows:
                return
            drives_payload = self.collect_drives_payload(select_all=False)
            selected_count = sum(1 for d in drives_payload.values() if d.get("included"))
            if selected_count == 0:
                self.status_label.set_text("Please select at least one drive first.")
                return
            dest = self.dest_entry.get_text().strip() or self.destination
            self._set_busy_state(True, f"Starting {selected_count} selected drive(s)...")
            self._send_ipc({
                "action": "start_copy",
                "mode": "selected",
                "destination": dest,
                "drives": drives_payload,
            })

        def _set_busy_state(self, busy, status_msg=None):
            self.is_busy = busy
            self.refresh_btn.set_sensitive(not busy)
            self.copy_all_btn.set_sensitive((not busy) and bool(self.drive_rows))
            self.start_selected_btn.set_sensitive((not busy) and bool(self.drive_rows))
            self.dest_entry.set_sensitive(not busy)
            self.browse_btn.set_sensitive(not busy)

            for widgets in self.drive_rows.values():
                widgets["check"].set_sensitive(not busy)
                widgets["author_entry"].set_sensitive(not busy)
                widgets["name_entry"].set_sensitive(not busy)

            if status_msg:
                self.status_label.set_text(status_msg)

            if busy:
                if self.pulse_timer_id is None:
                    self.pulse_timer_id = GLib.timeout_add(150, self._on_pulse_timer)
            else:
                if self.pulse_timer_id is not None:
                    GLib.source_remove(self.pulse_timer_id)
                    self.pulse_timer_id = None

        def _on_pulse_timer(self):
            if not self.is_busy:
                self.pulse_timer_id = None
                return False
            if getattr(self, "_pulsing_mode", False):
                self.progress_bar.pulse()
            return True

        def append_log(self, text):
            if not text:
                return
            end_iter = self.log_buffer.get_end_iter()
            line = text if text.endswith("\n") else text + "\n"
            self.log_buffer.insert(end_iter, line)
            mark = self.log_buffer.create_mark(None, self.log_buffer.get_end_iter(), False)
            self.log_view.scroll_to_mark(mark, 0.0, False, 0.0, 1.0)

        def handle_backend_message(self, msg):
            msg_type = msg.get("type")

            if msg_type == "drives_list":
                drives = msg.get("drives") or {}
                self.populate_drives(drives)
                if self.self_test:
                    self._run_self_test_assertions(drives)

            elif msg_type == "job_started":
                self._pulsing_mode = True
                self.progress_bar.set_fraction(0.0)
                self.progress_bar.set_text("Starting...")
                self.append_log(msg.get("message", "Job started."))

            elif msg_type == "progress":
                ev = msg.get("event")
                drive = msg.get("drive", "")
                idx = msg.get("drive_index", 1)
                total = msg.get("total_drives", 1)
                fraction = msg.get("fraction")
                status_text = msg.get("status_text")
                text = msg.get("message", "")

                if ev == "drive_start":
                    self._pulsing_mode = True
                    self.status_label.set_text(f"[{idx}/{total}] Processing {drive}...")
                    self.progress_bar.set_text(f"Drive {idx}/{total}: {drive}")
                    self.append_log(text)
                elif ev == "log":
                    if fraction is not None:
                        self._pulsing_mode = False
                        self.progress_bar.set_fraction(float(fraction))
                    else:
                        self._pulsing_mode = True

                    if status_text:
                        self.status_label.set_text(f"[{idx}/{total}] {drive}: {status_text}")
                        self.progress_bar.set_text(status_text)
                    self.append_log(text)
                elif ev == "drive_done":
                    self._pulsing_mode = False
                    if fraction is not None:
                        self.progress_bar.set_fraction(float(fraction))
                    self.status_label.set_text(f"[{idx}/{total}] Finished & ejected {drive}")
                    self.append_log(text)
                elif ev == "error":
                    self._pulsing_mode = False
                    self.status_label.set_text(f"[{idx}/{total}] Error on {drive}")
                    self.append_log(f"ERROR: {text}")

            elif msg_type == "job_finished":
                self._pulsing_mode = False
                success = msg.get("success", True)
                summary = msg.get("message", "Done.")
                self.progress_bar.set_fraction(1.0 if success else 0.0)
                self.progress_bar.set_text("Completed" if success else "Stopped / Error")
                self._set_busy_state(False, summary)
                self.append_log(summary)

            elif msg_type == "ack_self_test":
                self.get_application().quit()

        def _run_self_test_assertions(self, detected_drives):
            # Verify synthetic drive row population if host has no drives inserted
            if not detected_drives:
                sample = {
                    "sr0": {
                        "drive": "/dev/sr0",
                        "type": "audio",
                        "mountpoint": "cdda://sr0/"
                    },
                    "sr1": {
                        "drive": "/dev/sr1",
                        "type": "mp3",
                        "mountpoint": "/media/cdrom0"
                    }
                }
                self.populate_drives(sample)
                payload = self.collect_drives_payload(select_all=True)
                assert "sr0" in payload and "sr1" in payload
                assert payload["sr0"]["author"] == "Unknown"
                self.populate_drives({})

            self._send_ipc({
                "action": "self_test_complete",
                "status": "ok",
                "widgets_verified": True
            })


    class CdForMeApp(Adw.Application):
        def __init__(self, destination, self_test=False):
            super().__init__(
                application_id="io.github.cdforme.App",
                flags=Gio.ApplicationFlags.NON_UNIQUE
            )
            self.destination = destination
            self.self_test = self_test
            self.win = None

        def do_activate(self):
            if not self.win:
                self.win = CdForMeWindow(
                    self,
                    destination=self.destination,
                    self_test=self.self_test
                )
                self._start_stdin_reader()

            if not self.self_test:
                self.win.present()

            GLib.idle_add(self.win.request_refresh)

        def _start_stdin_reader(self):
            def reader():
                for line in sys.stdin:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        msg = json.loads(line)
                        GLib.idle_add(self.win.handle_backend_message, msg)
                    except Exception:
                        pass

            t = threading.Thread(target=reader, daemon=True)
            t.start()


    def main():
        parser = argparse.ArgumentParser()
        parser.add_argument("--destination", default="~/Musik")
        parser.add_argument("--self-test", action="store_true")
        args, _ = parser.parse_known_args()

        app = CdForMeApp(destination=args.destination, self_test=args.self_test)
        app.run([])

    if __name__ == "__main__":
        main()
  PYTHON
end
