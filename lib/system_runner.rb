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

  def run_stream(*args, &block)
    dry_run(args)

    stdin, stdout_and_stderr, wait_thr = Open3.popen2e(*args.join(" "))
    stdin.close

    stdout_and_stderr.each_line do |line|
      block.call(line) if block_given?
    end
    stdout_and_stderr.close

    wait_thr.value.success?
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

    status = wait_thr.value
    puts error_output if verbose && !error_output.empty?
    return "" unless status.success?

    output
  end
end