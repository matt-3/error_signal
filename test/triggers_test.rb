# frozen_string_literal: true

require "test_helper"

# Choosing what posts: ERROR_SIGNAL_IGNORE_SOURCES, ERROR_SIGNAL_REPORT_HANDLED
# and the ErrorSignal.ignore_if rules.
class TriggersTest < ErrorSignalTestCase
  setup do
    ENV["DISCORD_WEBHOOK_URL"] = WEBHOOK
  end

  SyncError = Class.new(StandardError)

  # ---- ERROR_SIGNAL_IGNORE_SOURCES -------------------------------------------

  test "ignores the sources that start with one of ERROR_SIGNAL_IGNORE_SOURCES" do
    ENV["ERROR_SIGNAL_IGNORE_SOURCES"] = "application.active_job, deprecation"

    posts = capturing_posts do
      report(raised(RuntimeError, "job"), source: "application.active_job")
      report(raised(RuntimeError, "deprecated"), source: "deprecation.rails")
      report(raised(RuntimeError, "request"), source: "application.action_dispatch")
    end

    assert_equal 1, posts.size
    assert_includes embed(posts.first)[:description], "request"
  end

  test "without ERROR_SIGNAL_IGNORE_SOURCES only the cache stores are ignored" do
    posts = capturing_posts do
      report(raised, source: "redis_cache_store.active_support")
      report(raised(RuntimeError, "job"), source: "application.active_job")
    end

    assert_equal 1, posts.size
  end

  test "a source list never matches an error without a source" do
    ENV["ERROR_SIGNAL_IGNORE_SOURCES"] = "application"

    posts = capturing_posts { report(raised, source: nil) }

    assert_equal 1, posts.size
  end

  # ---- ERROR_SIGNAL_REPORT_HANDLED -------------------------------------------

  test "handled errors post by default" do
    posts = capturing_posts { report(raised, handled: true) }

    assert_equal 1, posts.size
  end

  test "ERROR_SIGNAL_REPORT_HANDLED=false keeps only what the app did not rescue" do
    ENV["ERROR_SIGNAL_REPORT_HANDLED"] = "false"

    posts = capturing_posts do
      report(raised(RuntimeError, "rescued"), handled: true)
      report(raised(RuntimeError, "escaped"), handled: false)
    end

    assert_equal 1, posts.size
    assert_includes embed(posts.first)[:description], "escaped"
  end

  test "ErrorSignal.notify posts even with ERROR_SIGNAL_REPORT_HANDLED=false" do
    ENV["ERROR_SIGNAL_REPORT_HANDLED"] = "false"

    posts = capturing_posts { ErrorSignal.notify(raised) }

    assert_equal 1, posts.size
  end

  # ---- ErrorSignal.ignore_if ---------------------------------------------------

  test "an ignore_if rule receives the error and the event and drops what it matches" do
    seen = []
    ErrorSignal.ignore_if do |error, event|
      seen << [ error.class, event.source, event.severity, event.handled, event.manual, event.context[:tag] ]
      error.is_a?(SyncError) && event.context[:tag] == "sync"
    end

    posts = capturing_posts do
      report(raised(SyncError, "a"), context: { tag: "sync" }, source: "application.active_job")
      report(raised(SyncError, "b"), context: { tag: "other" })
    end

    assert_equal 1, posts.size
    assert_equal [ SyncError, "application.active_job", :error, false, false, "sync" ], seen.first
  end

  test "rules add up" do
    ErrorSignal.ignore_if { |error, _| error.message == "one" }
    ErrorSignal.ignore_if { |error, _| error.message == "two" }

    posts = capturing_posts do
      %w[one two three].each { |message| report(raised(RuntimeError, message)) }
    end

    assert_equal 1, posts.size
    assert_includes embed(posts.first)[:description], "three"
  end

  test "a rule that raises does not stop the alert" do
    ErrorSignal.ignore_if { |_error, _event| raise "broken rule" }

    posts = capturing_posts { report(raised) }

    assert_equal 1, posts.size
  end

  test "ignore_if marks ErrorSignal.notify as manual" do
    ErrorSignal.ignore_if { |_error, event| !event.manual }

    posts = capturing_posts do
      report(raised(RuntimeError, "automatic"))
      ErrorSignal.notify(raised(RuntimeError, "by hand"))
    end

    assert_equal 1, posts.size
    assert_includes embed(posts.first)[:description], "by hand"
  end

  test "ignore_if needs a block" do
    assert_raises(ArgumentError) { ErrorSignal.ignore_if }
  end
end
