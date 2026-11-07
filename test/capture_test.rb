# frozen_string_literal: true

require "test_helper"
require "rake"
require "open3"
require "socket"

# Errors that end a rake task or `rails runner`: posted once (never twice
# when Rails.error already saw them), and before the process exits.
class CaptureTest < ErrorSignalTestCase
  Capture = ErrorSignal::Capture

  setup do
    ENV["DISCORD_WEBHOOK_URL"] = WEBHOOK
    Capture.install_rake_hook
  end

  # Runs `task_name` in a fresh Rake application, the way `rake` and
  # `bin/rails` do: inside standard_exception_handling, which exits.
  def run_rake(task_name)
    app = Rake::Application.new
    app.options.trace_output = StringIO.new # "rake aborted!" and the backtrace
    Rake.with_application(app) do
      yield
      capture_io do
        app.standard_exception_handling { app.invoke_task(task_name) }
      rescue SystemExit
        nil
      end
    end
  end

  # ---- rake, in process ------------------------------------------------------

  test "the hook is prepended once to Rake::Application" do
    Capture.install_rake_hook

    assert_equal 1, Rake::Application.ancestors.count(Capture::RakeApplication)
  end

  test "an exception that ends a rake task is posted once, with the task" do
    posts = capturing_posts do
      run_rake("boom") { Rake::Task.define_task("boom") { raise KeyError, "boom in a task" } }
    end

    assert_equal 1, posts.size
    assert_includes title(posts.first), "KeyError"
    assert_equal Capture::RAKE_SOURCE, field_value(posts.first, "Source")
    assert_equal "boom", field_value(posts.first, "Task")
  end

  test "a failing prerequisite is the task shown" do
    posts = capturing_posts do
      run_rake("outer") do
        Rake::Task.define_task("inner") { raise IndexError, "in the prerequisite" }
        Rake::Task.define_task("outer" => "inner")
      end
    end

    assert_equal "inner", field_value(posts.first, "Task")
  end

  test "an error that went through Rails.error inside the task is not posted twice" do
    posts = capturing_posts do
      run_rake("recorded") do
        Rake::Task.define_task("recorded") { Rails.error.record { raise KeyError, "recorded" } }
      end
    end

    assert_equal 1, posts.size
    assert_equal "application", field_value(posts.first, "Source"), "the post is the one from Rails.error"
  end

  test "abort, exit and Ctrl-C are not errors" do
    posts = capturing_posts do
      run_rake("stop") { Rake::Task.define_task("stop") { abort "stopped" } }
      run_rake("interrupted") { Rake::Task.define_task("interrupted") { raise Interrupt } }
    end

    assert_empty posts
  end

  test "an error a task rescues is not posted" do
    posts = capturing_posts do
      run_rake("careful") do
        Rake::Task.define_task("careful") do
          raise KeyError, "handled"
        rescue KeyError
          nil
        end
      end
    end

    assert_empty posts
  end

  # ---- runner, in process ----------------------------------------------------

  test "the runner hook posts the exception that ends the process" do
    error = NotImplementedError.new("missing") # a ScriptError: the executor does not rescue it
    error.set_backtrace(caller)

    posts = capturing_posts { Capture.runner_exit(error) }

    assert_equal 1, posts.size
    assert_equal Capture::RUNNER_SOURCE, field_value(posts.first, "Source")
  end

  test "the runner hook skips what Rails.error already reported, exits and a clean end" do
    reported = raised(KeyError, "reported by the executor")

    posts = capturing_posts do
      Rails.error.report(reported, handled: false)
      Capture.runner_exit(reported)
      Capture.runner_exit(SystemExit.new(1))
      Capture.runner_exit(nil)
    end

    assert_equal 1, posts.size, "only the post from Rails.error"
  end

  test "the runner hook skips what Error Signal already saw, even if it was not posted" do
    ignored = raised(KeyError, "ignored")
    ENV["ERROR_SIGNAL_IGNORE_EXCEPTIONS"] = "KeyError"
    report(ignored)
    ENV.delete("ERROR_SIGNAL_IGNORE_EXCEPTIONS")

    posts = capturing_posts { Capture.runner_exit(ignored) }

    assert_empty posts
  end

  # ---- real processes --------------------------------------------------------

  # A local webhook: collects the bodies the child process posts, with the
  # User-Agent they came with under "_user_agent" and the name of an
  # attached file, when there is one, under "_attachment".
  def with_webhook
    server = TCPServer.new("127.0.0.1", 0)
    bodies = Queue.new
    thread = Thread.new do
      loop do
        client = server.accept
        length = 0
        agent = nil
        type = ""
        while (line = client.gets) && line != "\r\n"
          name, value = line.split(":", 2)
          length = value.to_i if name.casecmp?("content-length")
          agent = value.strip if name.casecmp?("user-agent")
          type = value.strip if name.casecmp?("content-type")
        end
        bodies << parse_webhook_body(client.read(length), type).merge("_user_agent" => agent)
        client.write("HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n")
        client.close
      end
    rescue IOError, SystemCallError
      nil
    end
    yield "http://127.0.0.1:#{server.addr[1]}/api/webhooks/1/test", bodies
  ensure
    server&.close
    thread&.kill
  end

  # JSON, or the multipart form a message with an attachment is sent as:
  # the "payload_json" part, plus the file name.
  def parse_webhook_body(body, type)
    return JSON.parse(body) unless type.start_with?("multipart/form-data")

    boundary = type[/boundary=(\S+)/, 1]
    parts = body.split("--#{boundary}")
    json = parts.find { |part| part.include?('name="payload_json"') }.split("\r\n\r\n", 2).last.chomp("\r\n")
    file = parts.find { |part| part.include?('name="files[0]"') }
    JSON.parse(json).merge("_attachment" => file && file[/filename="([^"]+)"/, 1])
  end

  def run_command(*args)
    posts = []
    with_webhook do |url, bodies|
      env = { "DISCORD_WEBHOOK_URL" => url, "ERROR_SIGNAL_ENVIRONMENTS" => "test", "ERROR_SIGNAL_LOCALE" => "en" }
      _out, _err, status = Open3.capture3(env, RbConfig.ruby, "-I", File.expand_path("../lib", __dir__),
        File.expand_path("fixtures/command_app.rb", __dir__), *args, chdir: File.expand_path("..", __dir__))
      refute status.success?, "the command should fail"
      posts << bodies.pop until bodies.empty?
    end
    posts
  end

  def source_of(post)
    post["embeds"].first["fields"].find { |f| f["name"] == "Source" }&.fetch("value")
  end

  test "rails runner: the error is posted once, before the process exits" do
    posts = run_command("runner", "raise KeyError, 'boom in the runner'")

    assert_equal 1, posts.size
    assert_includes posts.first["embeds"].first["title"], "KeyError"
    assert_equal "application.runner.railties", source_of(posts.first), "Rails reports it through the executor"
    assert_equal "Error Signal", posts.first["username"]
    assert_equal ErrorSignal::Delivery::USER_AGENT, posts.first["_user_agent"]
  end

  test "rails runner --skip-executor: the at_exit hook posts it" do
    require "rails/command"
    require "rails/commands/runner/runner_command"
    skip "this Rails has no --skip-executor" unless Rails::Command::RunnerCommand.class_options.key?(:skip_executor)

    posts = run_command("runner", "--skip-executor", "raise KeyError, 'boom without the executor'")

    assert_equal 1, posts.size
    assert_equal Capture::RUNNER_SOURCE, source_of(posts.first)
  end

  test "rake: the error is posted once, with the task, before the process exits" do
    posts = run_command("rake", "outer")

    assert_equal 1, posts.size
    fields = posts.first["embeds"].first["fields"]
    assert_equal "inner", fields.find { |f| f["name"] == "Task" }["value"]
    assert_equal Capture::RAKE_SOURCE, source_of(posts.first)
  end

  test "rake: an error Rails.error saw inside the task is posted once" do
    posts = run_command("rake", "recorded")

    assert_equal 1, posts.size
    assert_equal "application", source_of(posts.first)
  end
end
