# frozen_string_literal: true

# Usage:
#   bin/rails error_signal:check            # shows the configuration, sends nothing
#   bin/rails error_signal:test             # sends a test error through Rails.error
#   bin/rails error_signal:test_repeat      # exercises the power-of-two grouping
#   bin/rails error_signal:clear_dedupe     # ends the current bursts: the next error posts right away
#   bin/rails "error_signal:digest[daily]"  # posts the daily report (or weekly)
#
# In production (e.g. Dokku):
#   dokku run <app> bin/rails error_signal:test

module ErrorSignal
  # Helpers in their own module: a bare `def` inside a Rake namespace defines
  # a method on Object (kernel pollution) that leaks into the whole app.
  module RakeHelpers
    SOURCE = "test.error_signal"

    # One class per task: the fingerprint includes the class, so an
    # `error_signal:test` must not count into the `error_signal:test_repeat`
    # after it.
    TestError = Class.new(StandardError)
    RepeatTestError = Class.new(StandardError)

    # Fits the longest label, "ERROR_SIGNAL_IGNORE_EXCEPTIONS:".
    LABEL_WIDTH = 32

    module_function

    # Reports the error through Rails.error, the same path a real error
    # takes, so the test also proves the subscription. Other subscribers
    # (Sentry, for instance) receive it too. Waits for the post: the rake
    # process would exit first.
    def send_test_notification(error)
      if ErrorSignal.subscribed?
        Rails.error.report(error, handled: false, severity: :error, source: SOURCE)
      else
        # Subscription removed by the app: still check the webhook.
        ErrorSignal.report(error, handled: false, severity: :error, source: SOURCE)
      end
      ErrorSignal.flush
    end

    def abort_unless_enabled!
      config = ErrorSignal::Config
      abort "DISCORD_WEBHOOK_URL is not set. Run `bin/rails error_signal:check` for details." if config.webhook_url.nil?
      return if config.environment_enabled?

      abort "Rails.env #{Rails.env} is not in ERROR_SIGNAL_ENVIRONMENTS (#{config.environments.join(', ')}), so nothing is posted here.\n" \
        "To try it in this environment: ERROR_SIGNAL_ENVIRONMENTS=#{Rails.env} bin/rails #{Rake.application.top_level_tasks.first}"
    end

    def mask_url(url)
      url.to_s.sub(%r{(/api/webhooks/\d+/).*}, '\1***')
    end

    # A real exception (with a real backtrace), so the payload is identical
    # to the one of a production error. A new one on each call: Rails.error
    # reports the same exception object only once.
    def raise_test_error(message, klass = TestError)
      raise klass, message
    rescue klass => e
      e
    end

    def line(label, value)
      puts "#{"#{label}:".ljust(LABEL_WIDTH)} #{value}"
    end

    def setting(name, value, default:)
      raw = ENV[name].presence
      "#{value} #{raw ? "(from #{raw.inspect})" : "(#{default})"}"
    end

    def store_line
      store = Rails.cache
      kind = ErrorSignal::Report.store_kind(store)
      meaning = {
        none: "keeps nothing: no grouping, every occurrence posts, reports are empty",
        process: "per process: grouping and reports cover one process and reset on restart",
        local: "local disk: shared by the processes of one machine, not across servers, lost if a deploy wipes the disk",
        shared: "shared and persistent: grouping and reports cover every process"
      }.fetch(kind)
      "#{store.class} - #{meaning}"
    end

    def history_line
      history = Rails.cache.read(ErrorSignal::Tracker::HISTORY_KEY)
      return "none yet (written by every report)" unless history.is_a?(Hash) && history["days"].is_a?(Hash)

      at = history["at"] ? Time.at(history["at"]).in_time_zone(ErrorSignal::Config.time_zone).strftime("%Y-%m-%d %H:%M %Z") : "?"
      "#{history['days'].size} of #{ErrorSignal::Report::HISTORY_DAYS} days, written #{at}"
    rescue StandardError => e
      "unreadable (#{e.class})"
    end
  end
end

namespace :error_signal do
  desc "Show the Error Signal configuration (sends nothing)"
  task check: :environment do
    config = ErrorSignal::Config
    h = ErrorSignal::RakeHelpers
    url = config.webhook_url
    window = config.grouping_window
    spike = config.spike_threshold
    packs = config.pii_rules

    h.line "DISCORD_WEBHOOK_URL", url ? "set (#{h.mask_url(url)})" : "MISSING - Error Signal is a no-op"
    h.line "DISCORD_MENTION", config.mention || "(none: new, regressed and spike messages ping nobody)"
    h.line "ERROR_SIGNAL_ENVIRONMENTS", h.setting("ERROR_SIGNAL_ENVIRONMENTS", config.environments.join(", "), default: "default") +
      " - Rails.env #{Rails.env} is #{config.environment_enabled? ? 'enabled' : 'NOT enabled: nothing is posted or counted here'}"
    h.line "ERROR_SIGNAL_APP_NAME", h.setting("ERROR_SIGNAL_APP_NAME", config.app_name, default: "the app module name")
    h.line "ERROR_SIGNAL_MIN_LEVEL", h.setting("ERROR_SIGNAL_MIN_LEVEL", ErrorSignal.min_level, default: "default")
    h.line "ERROR_SIGNAL_LOCALE", h.setting("ERROR_SIGNAL_LOCALE", ErrorSignal.locale, default: "default")
    h.line "ERROR_SIGNAL_GROUPING_WINDOW", h.setting("ERROR_SIGNAL_GROUPING_WINDOW", "#{window} s (#{window / 60} min)", default: "default")
    h.line "ERROR_SIGNAL_SPIKE", h.setting("ERROR_SIGNAL_SPIKE", spike.positive? ? "more than #{spike} in 5 min" : "off", default: "default")
    h.line "ERROR_SIGNAL_IGNORE_EXCEPTIONS", config.ignored_exceptions.join(", ").presence || "(none)"
    h.line "ERROR_SIGNAL_IGNORE_CRAWLERS", h.setting("ERROR_SIGNAL_IGNORE_CRAWLERS", config.ignore_crawlers? ? "yes" : "no", default: "default")
    h.line "ERROR_SIGNAL_IGNORE_SOURCES", config.ignored_sources.join(", ").presence || "(none besides the cache stores)"
    h.line "ERROR_SIGNAL_REPORT_HANDLED", h.setting("ERROR_SIGNAL_REPORT_HANDLED",
      config.report_handled? ? "yes" : "no: only what the app did not rescue", default: "default")
    rules = ErrorSignal.ignore_rules.size
    h.line "ErrorSignal.ignore_if", rules.zero? ? "(no rules)" : "#{rules} rule(s)"
    h.line "ERROR_SIGNAL_PII_RULES", packs.any? ? packs.join(", ") : "(none: global rules only)"
    h.line "ERROR_SIGNAL_MASK", h.setting("ERROR_SIGNAL_MASK",
      config.mask == "full" ? "full: personal data becomes [FILTERED]" : "partial: personal data keeps a part", default: "default")
    h.line "Release", config.release || "(none: set ERROR_SIGNAL_RELEASE, SENTRY_RELEASE or GIT_REV; regressions need it)"
    h.line "Rails.error", ErrorSignal.subscribed? ? "subscribed" : "NOT subscribed - errors do not reach Error Signal"
    h.line "Sanitizer", ErrorSignal.sanitizer_name
    h.line "Rails.env", Rails.env
    h.line "Cache store", h.store_line
    h.line "Report time zone", config.time_zone.name
    h.line "Report history", h.history_line
    h.line "Gem version", ErrorSignal::VERSION

    if url.nil?
      puts
      puts "To configure it: set DISCORD_WEBHOOK_URL in the app environment"
      puts "(e.g. `dokku config:set <app> DISCORD_WEBHOOK_URL=...`, or your platform's secrets)."
    end
  end

  desc "Send a test error to Discord through Rails.error"
  task test: :environment do
    h = ErrorSignal::RakeHelpers
    h.abort_unless_enabled!

    error = h.raise_test_error("Error Signal test - triggered by bin/rails error_signal:test at #{Time.current}")

    puts "Sending a test error through Rails.error..."
    h.send_test_notification(error)
    puts "Sent. Check the Discord channel."
    puts "Other Rails.error subscribers (Sentry, for instance) receive this test error too."
    puts
    puts "If nothing arrived, check that:"
    puts "  1. the webhook URL is correct and Rails.error is subscribed (`bin/rails error_signal:check`)"
    puts "  2. the Rails log has an [ErrorSignal] line"
    puts "  3. the webhook was not deleted in Discord"
    puts "  4. the same test did not run in the last #{ErrorSignal::Config.grouping_window / 60} min (`bin/rails error_signal:clear_dedupe` resets it)"
  end

  desc "Report the same error 5 times to see the power-of-two grouping"
  task test_repeat: :environment do
    h = ErrorSignal::RakeHelpers
    h.abort_unless_enabled!

    puts "Reporting the SAME error 5 times in a row..."
    5.times do |i|
      h.send_test_notification(h.raise_test_error("Error Signal grouping test", h::RepeatTestError))
      print "#{i + 1} "
    end
    puts
    puts
    puts "Expected: 3 messages, for the 1st, 2nd and 4th occurrences (the 3rd and 5th are counted, not posted)."
    puts "Run it again within #{ErrorSignal::Config.grouping_window / 60} min and the 8th occurrence posts."
  end

  desc "End the current burst of the recent error groups, so the next error posts right away (keeps the report data)"
  task clear_dedupe: :environment do
    count = ErrorSignal::Tracker.clear_grouping
    puts "Reset the grouping of #{count} error group(s): the next occurrence of each posts as the 1st."
    puts "Only Error Signal's own keys were touched; the rest of the cache and the report data stay."
  end

  desc "Post the error report: error_signal:digest[daily] (the previous day) or error_signal:digest[weekly] (the last 7 days)"
  task :digest, [ :period ] => :environment do |_task, args|
    period = args[:period].presence || "daily"
    status, detail = ErrorSignal::Report.deliver(period)

    case status
    when :sent then puts "Sent the #{period} report: #{detail}"
    when :disabled then puts "Not sent: #{detail}."
    else abort "The #{period} report was not sent: #{detail}"
    end
  end
end
