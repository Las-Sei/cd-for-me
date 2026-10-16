require "open3"

module SystemRunner
  extend self

  def run(*args)
    execute_command(false, args)
  end

  def run_verbose(*args)
    execute_command(true, args)   
  end

  private

  def execute_command(verbose, *args)
    stdin, stdout, stderr, wait_thr = Open3.popen3(*args.join(" ")) #ToDo Args müssten hier auch als array/enumerable gehen
    stdin.close

    has_error = stderr.read != ""
    stderr.close
    return "" if has_error
    
    output = stdout.read
    stdout.close
    
    output
  end
end