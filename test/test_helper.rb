# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"

require "logger"
require "rails"
require "action_controller/railtie"
require "active_job/railtie"
require "active_support/test_case"
require "active_support/testing/time_helpers"
require "minitest/autorun"

require "error_signal"

# A small but real Rails app: Error Signal is subscribed to Rails.error by the
# gem's Railtie, and the integration tests raise through a real middleware
# stack and a real Active Job. The settings mirror production where it matters:
# no code reloading (so no ActionDispatch::Reloader, which reports from inside
# the stack in development), errors are not shown in detail, and ShowExceptions
# renders every exception.
class ErrorSignalTestApp < Rails::Application
  config.root = File.expand_path("..", __dir__)
  config.enable_reloading = false
  config.eager_load = false
  config.logger = Logger.new(nil)
  config.cache_store = :memory_store
  # The format every supported Rails reads (7.1 still defaults to 6.1).
  config.active_support.cache_format_version = 7.1
  # Rails 8.0 warns until the 8.1 behavior is chosen; 8.1 has only that one.
  config.active_support.to_time_preserves_timezone = :zone if Rails.gem_version.segments.first(2) == [ 8, 0 ]
  config.secret_key_base = "test"
  config.hosts.clear
  config.consider_all_requests_local = false
  config.action_dispatch.show_exceptions = :all
  config.active_job.queue_adapter = :inline
end
ErrorSignalTestApp.initialize!

class BoomController < ActionController::Base
  def show
    raise ArgumentError, "boom in a request for joao@example.com"
  end

  def missing
    raise ActionController::RoutingError, "no such page"
  end
end

class BoomJob < ActiveJob::Base
  def perform(message)
    raise KeyError, message
  end
end

ErrorSignalTestApp.routes.draw do
  get "/boom", to: "boom#show"
  get "/missing", to: "boom#missing"
  # A Rack endpoint, not a controller: Rails reports its errors with no
  # controller in the context.
  get "/rack_boom", to: ->(_env) { raise IndexError, "boom outside a controller" }
end

module StubHelper
  # Replaces a class method during the block and restores the original at the end.
  def stub_class_method(klass, method, callable)
    original = klass.method(method)
    klass.define_singleton_method(method) { |*args, **kwargs| callable.call(*args, **kwargs) }
    yield
  ensure
    klass.singleton_class.send(:remove_method, method)
    klass.define_singleton_method(method, original)
  end

  # Replaces an instance method on a single object, during the block.
  def stub_instance_method(obj, method, callable)
    obj.define_singleton_method(method) { |*args, **kwargs| callable.call(*args, **kwargs) }
    yield
  ensure
    obj.singleton_class.send(:remove_method, method)
  end
end

# Shared setup for Error Signal tests: a clean environment (enabled in the
# test env), a real MemoryStore (the grouping and the reports live in the
# cache) and helpers to capture the posts without touching the network.
class ErrorSignalTestCase < ActiveSupport::TestCase
  include StubHelper
  include ActiveSupport::Testing::TimeHelpers

  WEBHOOK = "https://discord.com/api/webhooks/123/abc"
  ENV_KEYS = %w[
    DISCORD_WEBHOOK_URL ERROR_SIGNAL_MIN_LEVEL ERROR_SIGNAL_APP_NAME ERROR_SIGNAL_LOCALE ERROR_SIGNAL_RELEASE
    ERROR_SIGNAL_ENVIRONMENTS ERROR_SIGNAL_IGNORE_EXCEPTIONS ERROR_SIGNAL_IGNORE_EXCEPTIONS_DEFAULTS
    ERROR_SIGNAL_IGNORE_CRAWLERS DISCORD_MENTION ERROR_SIGNAL_GROUPING_WINDOW ERROR_SIGNAL_SPIKE ERROR_SIGNAL_PII_RULES
    ERROR_SIGNAL_MASK ERROR_SIGNAL_IGNORE_SOURCES ERROR_SIGNAL_REPORT_HANDLED
    ERROR_SIGNAL_CONTEXT ERROR_SIGNAL_PROCESS ERROR_SIGNAL_USER DYNO
    SENTRY_RELEASE GIT_REV
  ].freeze

  setup do
    @original_env = ENV.to_h.slice(*ENV_KEYS)
    ENV_KEYS.each { |k| ENV.delete(k) }
    # The default is production only; the suite runs in "test".
    ENV["ERROR_SIGNAL_ENVIRONMENTS"] = "test"

    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    ErrorSignal.sanitizer = nil
    ErrorSignal.ignore_rules.clear
  end

  teardown do
    Rails.cache = @original_cache
    ErrorSignal.sanitizer = nil
    ErrorSignal.ignore_rules.clear
    ENV_KEYS.each { |k| ENV.delete(k) }
    @original_env.each { |k, v| ENV[k] = v }
  end

  # Intercepts every post (alerts from the thread, reports in line) and
  # returns the payloads, without touching the network. The alert post is
  # made synchronous, so the test does not depend on Thread timing.
  def capturing_posts
    posted = []
    stub_class_method(ErrorSignal::Delivery, :post, ->(payload) { posted << payload; true }) do
      stub_class_method(ErrorSignal::Delivery, :post_async, ->(payload) { ErrorSignal::Delivery.post(payload) }) do
        yield posted
      end
    end
    posted
  end

  # What Rails.error hands the subscriber for an error that escaped the app.
  # Goes straight to the subscriber: Rails.error itself reports an exception
  # object only once, and the grouping tests report the same one many times.
  def report(error, handled: false, severity: :error, context: {}, source: "application")
    ErrorSignal.subscriber.report(error, handled: handled, severity: severity, context: context, source: source)
  end

  def raised(klass = RuntimeError, message = "boom")
    raise klass, message
  rescue StandardError => e
    e
  end

  def embed(post)
    post[:embeds].first
  end

  def title(post)
    embed(post)[:title]
  end

  def field_names(post)
    embed(post)[:fields].map { |f| f[:name] }
  end

  def field_value(post, name)
    embed(post)[:fields].find { |f| f[:name] == name }&.dig(:value)
  end

  def json(payload)
    JSON.generate(payload)
  end

  # Every Discord limit for a message with embeds.
  def assert_within_discord_limits(post)
    post[:embeds].each do |embed|
      assert_operator embed[:title].length, :<=, 256
      assert_operator embed[:description].to_s.length, :<=, 4096
      assert_operator embed[:fields].size, :<=, 25
      embed[:fields].each do |f|
        assert_operator f[:name].length, :<=, 256
        assert_operator f[:value].length, :<=, 1024, f[:name]
      end
      size = embed[:title].length + embed[:description].to_s.length + embed[:footer][:text].length +
        embed[:fields].sum { |f| f[:name].length + f[:value].length }
      assert_operator size, :<=, 6000
    end
    assert_operator post[:username].length, :<=, 80
  end
end
