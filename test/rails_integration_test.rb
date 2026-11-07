# frozen_string_literal: true

require "test_helper"

# Proves Error Signal receives errors from a real Rails app with no Sentry and
# no call in the app: the Railtie subscribes it to Rails.error, and Rails
# reports there what escapes a request (ActionDispatch::Executor, source
# "application.action_dispatch") and what escapes a job run inside the
# executor (ActiveSupport::ExecutionWrapper.wrap, source "application.active_support").
class RailsIntegrationTest < ErrorSignalTestCase
  setup do
    ENV["DISCORD_WEBHOOK_URL"] = WEBHOOK
  end

  def get(path, headers = {})
    Rack::MockRequest.new(ErrorSignalTestApp).get(path, headers)
  end

  # ---- subscription ----------------------------------------------------------

  test "the Railtie subscribes Error Signal to Rails.error" do
    subscribers = Rails.error.instance_variable_get(:@subscribers)

    assert_includes subscribers, ErrorSignal.subscriber
    assert ErrorSignal.subscribed?
  end

  test "subscribing again does not register a second subscriber" do
    ErrorSignal.subscribe!(Rails.error)
    ErrorSignal.subscribe!(Rails.error)

    subscribers = Rails.error.instance_variable_get(:@subscribers)
    assert_equal 1, subscribers.count { |s| s.is_a?(ErrorSignal::Subscriber) }
  end

  test "Rails.error.disable silences Error Signal, as Rails documents" do
    posts = capturing_posts do
      Rails.error.disable(ErrorSignal::Subscriber) do
        Rails.error.report(raised, handled: false)
      end
    end

    assert_empty posts
  end

  # ---- requests --------------------------------------------------------------

  test "an error raised in a controller action is posted once, with the request context" do
    posts = capturing_posts do
      response = get("/boom", "HTTP_X_REQUEST_ID" => "req-abc-123")
      assert_equal 500, response.status
    end

    assert_equal 1, posts.size
    post = posts.first
    assert_includes embed(post)[:title], "ArgumentError"
    assert_equal "error", field_value(post, "Level")
    assert_equal "application.action_dispatch", field_value(post, "Source")
    assert_equal "BoomController#show", field_value(post, "Request")
    assert_equal "req-abc-123", field_value(post, "Request ID")
    assert_includes field_value(post, "Backtrace"), "test/test_helper.rb"
    refute_includes json(post), "joao@example.com", "the built-in sanitizer filters the message"
  end

  test "a request error answered with a 404 is not posted" do
    posts = capturing_posts do
      assert_equal 404, get("/missing").status
      assert_equal 404, get("/no-such-route").status
    end

    assert_empty posts
  end

  test "the same request error in a loop posts its 1st, 2nd and 4th occurrences" do
    posts = capturing_posts { 5.times { get("/boom") } }

    assert_equal 3, posts.size
  end

  test "the Railtie puts the request tracker at the top of the middleware stack" do
    assert_equal ErrorSignal::RequestTracker, ErrorSignalTestApp.middleware.first.klass
  end

  test "an error outside a controller is posted with the request id kept by the tracker" do
    posts = capturing_posts do
      assert_equal 500, get("/rack_boom", "HTTP_X_REQUEST_ID" => "req-rack-1").status
    end

    assert_equal 1, posts.size
    assert_includes embed(posts.first)[:title], "IndexError"
    assert_equal "req-rack-1", field_value(posts.first, "Request ID")
    refute_includes field_names(posts.first), "Request"
  end

  # ---- crawlers --------------------------------------------------------------

  GOOGLEBOT = "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"
  CHROME = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36"

  test "a crawler's request error is not posted, a browser's is" do
    posts = capturing_posts do
      assert_equal 500, get("/boom", "HTTP_USER_AGENT" => GOOGLEBOT).status
      assert_equal 500, get("/boom", "HTTP_USER_AGENT" => CHROME).status
    end

    assert_equal 1, posts.size
  end

  test "a crawler's error outside a controller is not posted either" do
    posts = capturing_posts do
      assert_equal 500, get("/rack_boom", "HTTP_USER_AGENT" => GOOGLEBOT).status
    end

    assert_empty posts
  end

  test "ERROR_SIGNAL_IGNORE_CRAWLERS=false posts crawler errors too" do
    ENV["ERROR_SIGNAL_IGNORE_CRAWLERS"] = "false"

    posts = capturing_posts { get("/boom", "HTTP_USER_AGENT" => GOOGLEBOT) }

    assert_equal 1, posts.size
  end

  test "the tracker forgets the request when it ends" do
    get("/boom", "HTTP_USER_AGENT" => GOOGLEBOT)

    assert_nil ErrorSignal::RequestTracker.current_env
  end

  # ---- jobs ------------------------------------------------------------------

  test "an error in a job performed inside the executor is posted, with the job context" do
    posts = capturing_posts do
      assert_raises(KeyError) do
        ErrorSignalTestApp.executor.wrap { BoomJob.perform_now("job failed for joao@example.com") }
      end
    end

    assert_equal 1, posts.size
    post = posts.first
    assert_includes embed(post)[:title], "KeyError"
    assert_equal "application.active_support", field_value(post, "Source")
    assert_equal "BoomJob", field_value(post, "Job")
    assert_match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/, field_value(post, "Job ID"))
    refute_includes json(post), "joao@example.com"
  end

  test "an error in a job run by a queue adapter is posted" do
    # The inline adapter calls ActiveJob::Base.execute, the entry point queue
    # backends use; it wraps the job in the app's reloader/executor. (Solid
    # Queue wraps it in the executor itself, with the source
    # "application.solid_queue".)
    posts = capturing_posts do
      assert_raises(KeyError) { BoomJob.perform_later("queued") }
    end

    assert_equal 1, posts.size
    assert_equal "BoomJob", field_value(posts.first, "Job")
  end

  test "perform_now outside any executor is not reported by Rails" do
    # Nothing wraps a bare perform_now (a console, a test, a rake task without
    # the executor): Rails.error never hears of it, the error just goes up to
    # the caller.
    posts = capturing_posts do
      assert_raises(KeyError) { BoomJob.perform_now("bare") }
    end

    assert_empty posts
  end

  # ---- handled reports -------------------------------------------------------

  test "Rails.error.handle is a handled warning and is not posted by default" do
    posts = capturing_posts do
      Rails.error.handle { raise "swallowed" }
    end

    assert_empty posts
  end

  test "Rails.error.record is posted" do
    posts = capturing_posts do
      assert_raises(RuntimeError) { Rails.error.record { raise "recorded" } }
    end

    assert_equal 1, posts.size
    assert_equal "application", field_value(posts.first, "Source")
  end
end
