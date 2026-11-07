# frozen_string_literal: true

require "digest"
require "json"
require "net/http"
require "stringio"
require "uri"
require "active_support"
require "active_support/core_ext"

require_relative "error_signal/version"
require_relative "error_signal/messages"
require_relative "error_signal/config"
require_relative "error_signal/text"
require_relative "error_signal/sanitizer"
require_relative "error_signal/fingerprint"
require_relative "error_signal/filters"
require_relative "error_signal/request_tracker"
require_relative "error_signal/tracker"
require_relative "error_signal/alert"
require_relative "error_signal/delivery"
require_relative "error_signal/report"
require_relative "error_signal/capture"
require_relative "error_signal/subscriber"

# Error Signal: Sentry-like alerts and daily/weekly error reports for Rails,
# posted to Discord. It posts the errors a Rails app reports to a Discord
# channel through a webhook, groups them, tells new and regressed errors
# apart, and sends daily and weekly reports. No service, no database (it
# keeps its counts in Rails.cache), no personal data.
#
# HOW IT HOOKS IN
#
# The Railtie subscribes Error Signal to Rails.error (ActiveSupport::ErrorReporter),
# the error reporting API every Rails app has. Rails itself reports there what
# escapes a request, a job run by a queue adapter and `rails runner`; the
# Capture hooks add what ends a rake task:
#
#   exception -> Rails.error -> [Discord] (+ any other subscriber, e.g. Sentry)
#
# PER ERROR
#
#   1. filters: webhook and environment, severity, 4xx request errors,
#      ignored classes, crawlers (Filters);
#   2. fingerprint: class + first app line + normalized message (Fingerprint);
#   3. counting in Rails.cache: burst, day, spike, new/regressed (Tracker);
#   4. a post on the 1st, 2nd, 4th, 8th... occurrence of a burst, and one
#      spike message per 5-minute window (Alert, Delivery).
#
# PRODUCTION GUARANTEES
#
# - Never raises. Any failure here is swallowed and logged: a webhook that is
#   down must not become an app error.
# - Does not block the request. The POST runs in a separate thread with
#   short timeouts; per error the request pays a few cache operations.
# - No PII. The message, the location, the backtrace and the ids go through
#   a sanitizer before leaving, and the report samples before they are
#   stored. If it fails, the text does not leave (fail-closed).
#
# The configuration is in environment variables (see Config and the README).
module ErrorSignal
  BUSY = :error_signal_busy
  SEEN = :@__error_signal_seen

  # What an `ignore_if` rule receives besides the exception. `manual` is
  # true for `ErrorSignal.notify`.
  Event = Struct.new(:source, :severity, :handled, :context, :manual, keyword_init: true)

  class << self
    attr_writer :sanitizer

    # The sanitizer in use: the one set with `ErrorSignal.sanitizer = ...`,
    # or the built-in one (with the packs of ERROR_SIGNAL_PII_RULES).
    def sanitizer
      @sanitizer || Sanitizer
    end

    # Which sanitizer is in use, for `error_signal:check`.
    def sanitizer_name
      @sanitizer ? "custom" : "built-in"
    end

    # Fail-closed: if the sanitizer raises, the localized "[sanitization
    # failed]" marker goes out instead of the text.
    def sanitize(value)
      sanitizer.call(value.to_s).to_s
    rescue StandardError
      translate(:sanitize_failed)
    end

    # The object registered in Rails.error.
    def subscriber
      @subscriber ||= Subscriber.new
    end

    # Registers Error Signal in `reporter` (Rails.error), once.
    def subscribe!(reporter)
      return if subscribed?(reporter)

      reporter.subscribe(subscriber)
      @subscribed_reporter = reporter
    end

    def subscribed?(reporter = nil)
      reporter ||= Rails.error if defined?(Rails) && Rails.respond_to?(:error)
      !reporter.nil? && @subscribed_reporter.equal?(reporter)
    end

    def locale
      Config.locale
    end

    def min_level
      Config.min_level
    end

    # Localized text for `key`, with `%{name}` placeholders filled from `values`.
    def translate(key, **values)
      template = MESSAGES.fetch(locale).fetch(key)
      values.empty? ? template : format(template, values)
    end

    # Called by Rails.error for every report (through Subscriber). NEVER raises.
    def report(error, handled:, severity:, context: {}, source: nil)
      process(error, handled: handled, severity: severity, context: context, source: source, manual: false)
    end

    # Adds a rule that decides, in Ruby, what is not posted. The block gets
    # the exception and an Event (source, severity, handled, context,
    # manual) and returns true to ignore it. Rules add up; a rule that
    # raises is skipped (the error is posted and the failure logged).
    #
    #   ErrorSignal.ignore_if { |error, event| error.is_a?(Timeout::Error) && event.context[:job].is_a?(SyncJob) }
    def ignore_if(&block)
      raise ArgumentError, "ErrorSignal.ignore_if needs a block" unless block

      ignore_rules << block
      block
    end

    def ignore_rules
      @ignore_rules ||= []
    end

    # Posts `exception` to Discord directly, without going through Rails.error
    # (other subscribers do not see it), with the same filters, grouping and
    # sanitizing. `context` takes the keys Rails gives subscribers
    # (`controller:`, `job:`), a plain `request_id:` and `rake_task:`.
    # NEVER raises.
    def notify(exception, context: {}, severity: :error)
      unless exception.is_a?(Exception)
        log_failure("notify expects an Exception, got #{exception.class}")
        return
      end

      process(exception, handled: true, severity: severity, context: context, source: nil, manual: true)
    end

    # Posts a message with no exception: something the app wants to tell
    # the channel ("stock of product 42 ran out"). Sanitized like an error,
    # colored by `level` (:info, :warning or :error), with `fields` (a hash,
    # name => value, at most 20) under it, and DISCORD_MENTION only with
    # `mention: true`. Messages with the same text (or the same `key:`)
    # are grouped like errors, posting the 1st, 2nd, 4th, 8th... within
    # ERROR_SIGNAL_GROUPING_WINDOW. Not counted in the error reports.
    # Returns true when the message goes out. NEVER raises.
    def message(text, level: :info, fields: {}, key: nil, mention: false)
      return false unless Config.enabled?

      text = text.to_s
      if text.strip.empty?
        log_failure("message expects a text")
        return false
      end

      level = Config.normalize_level(level) || "info"
      occurrence = Tracker.track_message(key.nil? ? text : key.to_s)
      return false unless occurrence.post

      Delivery.post_async(Alert.message(text, level: level, fields: fields, occurrence: occurrence, mention: mention))
      true
    rescue StandardError => e
      log_failure("error while preparing the message", e)
      false
    end

    # Waits for the posts in flight (at most a few seconds). The Railtie
    # calls it at exit; call it yourself before a script ends with `exit!`.
    def flush(timeout = Delivery::FLUSH_TIMEOUT)
      Delivery.flush(timeout)
    end

    # The exception went through Error Signal or through Rails.error.
    def already_reported?(error)
      error.instance_variable_defined?(SEEN) || error.instance_variable_defined?(:@__rails_error_reported)
    rescue StandardError
      false
    end

    def log_failure(context, error = nil)
      detail = error ? ": #{error.class} #{error.message}" : ""
      Rails.logger&.warn("[ErrorSignal] #{context}#{detail}")
    rescue StandardError
      nil
    end

    # DigestJob is defined when Active Job loads (see the Railtie). A
    # reference that comes first (a Solid Queue recurring task validated at
    # boot in development, where nothing is eager loaded) loads Active Job
    # here, which defines it.
    def const_missing(name)
      return super unless name == :DigestJob && defined?(::ActiveJob)

      ::ActiveJob::Base.name # loading it runs the on_load hook that defines the job
      require_relative "error_signal/digest_job" unless const_defined?(:DigestJob, false)
      const_get(:DigestJob, false)
    end

    private

    def process(error, handled:, severity:, context:, source:, manual:)
      return unless error.is_a?(Exception)
      return unless Config.enabled?

      mark_seen(error)

      # Something reported to Rails.error while we work (a cache store
      # reporting its own failure, for instance) must not come back in here.
      return if Thread.current[BUSY]

      begin
        Thread.current[BUSY] = true
        context = context.is_a?(Hash) ? context : {}
        event = Event.new(source: source, severity: severity, handled: handled, context: context, manual: manual)
        deliver(error, handled: handled, severity: severity, context: context, source: source) if reportable?(error, event)
      ensure
        Thread.current[BUSY] = nil
      end

      nil
    rescue StandardError => e
      log_failure("error while preparing the notification", e)
      nil
    end

    def mark_seen(error)
      error.instance_variable_set(SEEN, true) unless error.frozen?
    rescue StandardError
      nil
    end

    def reportable?(error, event)
      source = event.source
      severity = event.severity
      return false if Filters.ignored_source?(source)
      return false if Filters.client_error?(error, source)
      # ERROR_SIGNAL_REPORT_HANDLED=false keeps what the app rescued out;
      # an explicit ErrorSignal.notify always goes.
      return false if event.handled && !event.manual && !Config.report_handled?

      # An unknown severity counts as error: better an extra alert than a lost one.
      level = Config.normalize_level(severity) || "error"
      return false if Config::SEVERITY_RANKS.fetch(level) < Config::SEVERITY_RANKS.fetch(min_level)

      !Filters.ignored_exception?(error) && !Filters.crawler?(event.context) && !Filters.ignored_by_rule?(error, event)
    end

    def deliver(error, handled:, severity:, context:, source:)
      fingerprint = Fingerprint.for(error)
      occurrence = Tracker.track(fingerprint)
      level = Config.normalize_level(severity) || "error"

      if occurrence.post
        Delivery.post_async(Alert.build(error, fingerprint: fingerprint, occurrence: occurrence, level: level,
          handled: handled, context: context, source: source))
      end
      Delivery.post_async(Alert.spike(error, fingerprint: fingerprint)) if occurrence.spike
    end
  end
end

require_relative "error_signal/railtie" if defined?(Rails::Railtie)
