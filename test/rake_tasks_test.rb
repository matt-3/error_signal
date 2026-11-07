# frozen_string_literal: true

require "test_helper"
require "rake"

# The `error_signal:*` tasks.
class RakeTasksTest < ErrorSignalTestCase
  setup do
    unless Rake::Task.task_defined?("error_signal:test")
      Rake::Task.define_task(:environment)
      load File.expand_path("../lib/error_signal/tasks/error_signal.rake", __dir__)
    end
    Rake::Task.tasks.each(&:reenable)
    ENV["DISCORD_WEBHOOK_URL"] = WEBHOOK
  end

  # A `error_signal:check` line: the label padded like the task pads it.
  def check_line(label, value)
    "#{"#{label}:".ljust(ErrorSignal::RakeHelpers::LABEL_WIDTH)} #{value}"
  end

  def run_task(name, *args)
    capture_io { Rake::Task[name].invoke(*args) }
  end

  test "error_signal:test posts once, through Rails.error" do
    posts = capturing_posts { run_task("error_signal:test") }

    assert_equal 1, posts.size
    assert_includes title(posts.first), "ErrorSignal::RakeHelpers::TestError"
    assert_equal ErrorSignal::RakeHelpers::SOURCE, field_value(posts.first, "Source")
  end

  test "error_signal:test_repeat posts the 1st, 2nd and 4th occurrences, even right after error_signal:test" do
    posts = capturing_posts do
      run_task("error_signal:test")
      run_task("error_signal:test_repeat")
    end

    assert_equal [ "TestError", "RepeatTestError", "RepeatTestError", "RepeatTestError" ],
      posts.map { |p| title(p)[/ErrorSignal::RakeHelpers::(\w+)/, 1] }
    assert_includes title(posts.last), "4th time"
  end

  test "error_signal:test refuses to run outside ERROR_SIGNAL_ENVIRONMENTS, and says how to" do
    ENV["ERROR_SIGNAL_ENVIRONMENTS"] = "production"
    Rake.application.top_level_tasks.replace([ "error_signal:test" ])

    posts = capturing_posts do
      error = assert_raises(SystemExit) { run_task("error_signal:test") }
      refute error.success?
    end

    assert_empty posts
  end

  test "error_signal:check shows the configuration, the store and the report settings" do
    ENV["ERROR_SIGNAL_MIN_LEVEL"] = "fatal"
    ENV["ERROR_SIGNAL_PII_RULES"] = "br"
    ENV["DISCORD_MENTION"] = "@here"

    out, = run_task("error_signal:check")

    assert_includes out, check_line("Rails.error", "subscribed")
    assert_includes out, check_line("ERROR_SIGNAL_MIN_LEVEL", "error (from \"fatal\")")
    assert_includes out, check_line("ERROR_SIGNAL_ENVIRONMENTS", "test (from \"test\") - Rails.env test is enabled")
    assert_includes out, check_line("DISCORD_MENTION", "@here")
    assert_includes out, check_line("ERROR_SIGNAL_APP_NAME", "errorsignaltestapp (the app module name)")
    assert_includes out, check_line("ERROR_SIGNAL_GROUPING_WINDOW", "3600 s (60 min) (default)")
    assert_includes out, check_line("ERROR_SIGNAL_SPIKE", "more than 50 in 5 min (default)")
    assert_includes out, check_line("ERROR_SIGNAL_IGNORE_EXCEPTIONS", "ActionController::InvalidAuthenticityToken")
    assert_includes out, check_line("ERROR_SIGNAL_PII_RULES", "br")
    assert_includes out, check_line("Sanitizer", "built-in")
    assert_includes out, check_line("Cache store", "ActiveSupport::Cache::MemoryStore - per process")
    assert_includes out, check_line("Report time zone", "UTC")
    assert_includes out, check_line("Report history", "none yet")
    refute_includes out, "/abc", "the webhook token is masked"
  end

  test "error_signal:check tells when the environment is not enabled" do
    ENV.delete("ERROR_SIGNAL_ENVIRONMENTS")

    out, = run_task("error_signal:check")

    assert_includes out, "production (default) - Rails.env test is NOT enabled"
  end

  test "the app name defaults to the app class when it is defined at the top level" do
    posts = capturing_posts { run_task("error_signal:test") }

    assert_includes title(posts.first), "[errorsignaltestapp]"
  end

  test "error_signal:clear_dedupe resets the grouping and keeps the rest of the cache" do
    Rails.cache.write("app:other", "kept")
    error = raised

    posts = capturing_posts do
      3.times { report(error) }
      out, = run_task("error_signal:clear_dedupe")
      assert_includes out, "Reset the grouping of 1 error group(s)"
      report(error)
    end

    assert_equal 3, posts.size, "1st, 2nd, then the 1st again"
    assert_equal "kept", Rails.cache.read("app:other")
  end

  test "error_signal:digest posts the daily report by default and the weekly on request" do
    posts = capturing_posts do
      out, = run_task("error_signal:digest")
      assert_includes out, "Sent the daily report"
      Rake::Task["error_signal:digest"].reenable
      run_task("error_signal:digest", "weekly")
    end

    assert_equal [ "Daily", "Weekly" ], posts.map { |p| title(p)[/Daily|Weekly/] }
  end

  test "error_signal:digest says when it is disabled and fails on an unknown period" do
    ENV["ERROR_SIGNAL_ENVIRONMENTS"] = "production"
    out, = run_task("error_signal:digest")
    assert_includes out, "Not sent: Rails.env test is not in ERROR_SIGNAL_ENVIRONMENTS"

    Rake::Task["error_signal:digest"].reenable
    assert_raises(SystemExit) { run_task("error_signal:digest", "monthly") }
  end
end
