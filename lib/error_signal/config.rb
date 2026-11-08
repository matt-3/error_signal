# frozen_string_literal: true

module ErrorSignal
  # The settings: DISCORD_WEBHOOK_URL and DISCORD_MENTION for the Discord
  # channel, ERROR_SIGNAL_* for the rest. Environment variables, read on
  # every use (a few hash lookups), so a change in ENV applies without a
  # restart. Every reader is total: an invalid value falls back to the
  # default and never raises.
  module Config
    DEFAULT_LOCALE = "en"
    DEFAULT_MIN_LEVEL = "error"
    DEFAULT_ENVIRONMENTS = %w[production].freeze

    # Exceptions that are noise wherever they come from. On the request path
    # Rails answers each of them with a 4xx, so the 4xx rule already drops
    # them; the list covers the other ways they reach Rails.error (reported
    # by app code with severity error, a job, a rake task, or a 5xx mapping
    # in config.action_dispatch.rescue_responses). RecordNotFound and
    # RoutingError are left out on purpose: the 4xx rule covers them in a
    # request, and in a job they are real bugs.
    DEFAULT_IGNORED_EXCEPTIONS = %w[
      ActionController::InvalidAuthenticityToken
      ActionController::UnknownFormat
      ActionController::BadRequest
      ActionDispatch::Http::MimeNegotiation::InvalidType
      ActionController::InvalidCrossOriginRequest
    ].freeze

    DEFAULT_GROUPING_WINDOW = 3600
    DEFAULT_SPIKE = 50

    PII_PACKS = %w[br us uk in eu].freeze

    # ErrorReporter severities, to compare against ERROR_SIGNAL_MIN_LEVEL.
    SEVERITY_RANKS = { "info" => 1, "warning" => 2, "error" => 3 }.freeze
    # ERROR_SIGNAL_MIN_LEVEL names with no ErrorReporter counterpart.
    LEVEL_ALIASES = { "debug" => "info", "warn" => "warning", "fatal" => "error" }.freeze

    # Discord mention syntax: @here, @everyone, <@&role_id>, <@user_id>.
    MENTION_TOKEN = /\A(?:@here|@everyone|<@&\d+>|<@!?\d+>)\z/

    DURATION = /\A(\d+)\s*(s|sec|secs|seconds?|m|min|mins|minutes?|h|hours?|d|days?)?\z/
    DURATION_UNITS = { "s" => 1, "m" => 60, "h" => 3600, "d" => 86_400 }.freeze

    FALSE_VALUES = %w[0 false no off].freeze

    module_function

    def webhook_url
      ENV["DISCORD_WEBHOOK_URL"].presence
    end

    def environments
      list(ENV["ERROR_SIGNAL_ENVIRONMENTS"]).map(&:downcase).presence || DEFAULT_ENVIRONMENTS
    end

    def environment_enabled?
      environments.include?(Rails.env.to_s.downcase)
    rescue StandardError
      false
    end

    # Error Signal does anything at all only with a webhook and in one of
    # ERROR_SIGNAL_ENVIRONMENTS.
    def enabled?
      !webhook_url.nil? && environment_enabled?
    end

    def ignored_exceptions
      defaults = flag("ERROR_SIGNAL_IGNORE_EXCEPTIONS_DEFAULTS", true) ? DEFAULT_IGNORED_EXCEPTIONS : []
      (defaults + list(ENV["ERROR_SIGNAL_IGNORE_EXCEPTIONS"])).uniq
    end

    def ignored_sources
      list(ENV["ERROR_SIGNAL_IGNORE_SOURCES"])
    end

    # false: only what the app did not rescue is posted (requests, jobs,
    # rake, runner, Rails.error.record); Rails.error.handle and
    # Rails.error.report, which default to handled, stay out.
    def report_handled?
      flag("ERROR_SIGNAL_REPORT_HANDLED", true)
    end

    # The context the app passes with the error, shown in the alert.
    def context?
      flag("ERROR_SIGNAL_CONTEXT", true)
    end

    # The user in the alert and the people count (Person).
    def user?
      flag("ERROR_SIGNAL_USER", true)
    end

    # The process that raised: ERROR_SIGNAL_PROCESS, or DYNO, which Dokku
    # and Heroku set ("web.1", "worker.1").
    def process_name
      ENV["ERROR_SIGNAL_PROCESS"].presence || ENV["DYNO"].presence
    end

    def ignore_crawlers?
      flag("ERROR_SIGNAL_IGNORE_CRAWLERS", true)
    end

    # Seconds. Accepts a number of seconds or a number with a unit: 90s, 30m,
    # 2h, 1d. Anything else, or zero, is the default (1 hour).
    def grouping_window
      duration(ENV["ERROR_SIGNAL_GROUPING_WINDOW"]) || DEFAULT_GROUPING_WINDOW
    end

    # Occurrences of one group within 5 minutes above which a spike message
    # goes out. 0 turns it off.
    def spike_threshold
      value = ENV["ERROR_SIGNAL_SPIKE"].to_s.strip
      return DEFAULT_SPIKE if value.empty?
      return 0 if FALSE_VALUES.include?(value.downcase)

      Integer(value, 10).clamp(0, 1_000_000)
    rescue ArgumentError
      DEFAULT_SPIKE
    end

    # The valid mention tokens of DISCORD_MENTION, joined by a space, or nil.
    def mention
      tokens = ENV["DISCORD_MENTION"].to_s.split(/[\s,]+/).grep(MENTION_TOKEN).uniq
      tokens.empty? ? nil : tokens.join(" ")
    end

    # `allowed_mentions` for a message that carries `mention`: Discord pings
    # exactly those, and nothing else in the message.
    def allowed_mentions_for(mention)
      tokens = mention.to_s.split
      allowed = { parse: [] }
      allowed[:parse] = [ "everyone" ] if tokens.intersect?(%w[@here @everyone])
      roles = tokens.filter_map { |t| t[/\A<@&(\d+)>\z/, 1] }
      users = tokens.filter_map { |t| t[/\A<@!?(\d+)>\z/, 1] }
      allowed[:roles] = roles if roles.any?
      allowed[:users] = users if users.any?
      allowed
    end

    # "partial" (the default): personal data keeps a part, so the alert
    # tells which record failed. "full": it becomes [FILTERED] whole.
    # Secrets are always filtered whole.
    def mask
      ENV["ERROR_SIGNAL_MASK"].to_s.strip.downcase == "full" ? "full" : "partial"
    end

    def pii_rules
      list(ENV["ERROR_SIGNAL_PII_RULES"]).map(&:downcase).select { |pack| PII_PACKS.include?(pack) }.uniq
    end

    # SENTRY_RELEASE and GIT_REV (set by Dokku) are the usual places a deploy
    # writes its release, so an app that has one needs no extra setting.
    def release
      ENV["ERROR_SIGNAL_RELEASE"].presence || ENV["SENTRY_RELEASE"].presence || ENV["GIT_REV"].presence
    end

    def app_name
      ENV["ERROR_SIGNAL_APP_NAME"].presence || default_app_name
    end

    # "myapp" for MyApp::Application; the class name itself for an app class
    # defined at the top level.
    def default_app_name
      app_class = Rails.application.class
      parent = app_class.module_parent
      (parent == Object ? app_class.name : parent.name).to_s.downcase
    rescue StandardError
      "app"
    end

    # Locale of the message labels. Accepts "pt-BR" in any case, with "-" or
    # "_", and plain "pt"; anything else is English.
    def locale
      requested = ENV["ERROR_SIGNAL_LOCALE"].to_s.strip.downcase.tr("_", "-")
      %w[pt pt-br].include?(requested) ? "pt-BR" : DEFAULT_LOCALE
    rescue StandardError
      DEFAULT_LOCALE
    end

    def min_level
      normalize_level(ENV["ERROR_SIGNAL_MIN_LEVEL"]) || DEFAULT_MIN_LEVEL
    end

    # "info", "warning", "error", or nil for an unknown value.
    def normalize_level(value)
      name = value.to_s.strip.downcase
      name = LEVEL_ALIASES.fetch(name, name)
      SEVERITY_RANKS.key?(name) ? name : nil
    end

    # Days for the reports follow the app's configured time zone
    # (config.time_zone), never the per-request Time.zone an app may set.
    def time_zone
      Time.zone_default || ActiveSupport::TimeZone["UTC"]
    end

    def list(value)
      value.to_s.split(",").map(&:strip).reject(&:empty?)
    end

    def flag(name, default)
      value = ENV[name].to_s.strip.downcase
      value.empty? ? default : !FALSE_VALUES.include?(value)
    end

    def duration(value)
      match = DURATION.match(value.to_s.strip.downcase)
      return nil unless match

      seconds = match[1].to_i * DURATION_UNITS.fetch(match[2].to_s[0], 1)
      seconds.positive? ? seconds : nil
    end
  end
end
