require "open3"

module SystemRunner
  extend self

  def dry_run(*args)
    puts args.join(" ")
  end

  def run(*args)
    execute_command(false, args)
  end

  def run_verbose(*args)
    execute_command(true, args)
  end

  def run_live(*args)
    flat_args = args.flatten.map(&:to_s)
    return false if flat_args.empty?

    dry_run(flat_args)

    Open3.popen2e(*flat_args) do |stdin, stdout_and_stderr, wait_thr|
      stdin.close
      stdout_and_stderr.each_line do |line|
        $stdout.print(line)
        $stdout.flush
      end
      wait_thr.value.success?
    end
  rescue Errno::ENOENT => e
    $stderr.puts("Command failed: #{e.message}")
    false
  end

  private

  def execute_command(verbose, *args)
    # puts *args.join(" ")
    dry_run(args)

    stdin, stdout, stderr, wait_thr = Open3.popen3(*args.join(" ")) #ToDo Args müssten hier auch als array ohne string.join gehen
    stdin.close

    output = stdout.read
    error_output = stderr.read
    stdout.close
    stderr.close

    puts error_output if verbose && !error_output.empty?
    return "" unless wait_thr.value.success?

    output
  end
end
