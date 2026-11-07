# frozen_string_literal: true

module ErrorSignal
  # What is never posted (nor counted in the reports).
  module Filters
    # Source Rails gives what escapes a request (ActionDispatch::Executor).
    REQUEST_SOURCE = "application.action_dispatch"

    # Cache store failures (Redis, Memcached) are reported as handled
    # warnings on every cache call while the store is down, and the grouping
    # itself depends on that cache: posting them would be a flood by
    # construction.
    IGNORED_SOURCES = /_cache_store\.active_support\z/

    # Search engines, SEO tools and AI crawlers by name, then the generic
    # words crawlers put in their User-Agent. "bot" alone needs a separator
    # after it (bingbot/2.0, Slackbot-LinkExpanding) or to be a word of its
    # own, and is never the end of "Cubot" (a phone brand), so real phones
    # are not taken for crawlers.
    CRAWLER = %r{
      Googlebot|bingbot|YandexBot|Baiduspider|DuckDuckBot|Applebot|AhrefsBot|SemrushBot|
      GPTBot|ClaudeBot|CCBot|Bytespider|PerplexityBot|
      (?<!cu)bot(?:[/\-;)+:]|\s*\(|\z)|\bbot\b|crawl|spider
    }ix

    module_function

    # The cache store sources, and the sources that start with one of
    # ERROR_SIGNAL_IGNORE_SOURCES (`application.active_job` ignores job
    # errors; the alert's Source field shows the name to copy).
    def ignored_source?(source)
      name = source.to_s
      return true if IGNORED_SOURCES.match?(name)
      return false if name.empty?

      Config.ignored_sources.any? { |prefix| name.start_with?(prefix) }
    end

    # One of the ErrorSignal.ignore_if rules returns true. A rule that
    # raises counts as "do not ignore": better an extra alert than a lost one.
    def ignored_by_rule?(error, event)
      ErrorSignal.ignore_rules.any? do |rule|
        rule.call(error, event)
      rescue StandardError => e
        ErrorSignal.log_failure("an ignore_if rule raised, posting anyway", e)
        false
      end
    end

    # A request error that Rails answers with a 4xx (RecordNotFound,
    # RoutingError, ParameterMissing...). ShowExceptions already keeps these
    # out of Rails.error, but with `show_exceptions = :none` they reach the
    # Executor's rescue and are reported anyway: same rule for both paths.
    def client_error?(error, source)
      return false unless source == REQUEST_SOURCE && defined?(::ActionDispatch::ExceptionWrapper)

      ::ActionDispatch::ExceptionWrapper.status_code_for_exception(error.class.name) < 500
    rescue StandardError
      false
    end

    # The class or any of its ancestors (modules included) is in
    # ERROR_SIGNAL_IGNORE_EXCEPTIONS or the defaults. Matched by name, so the
    # listed constants do not need to be loaded.
    def ignored_exception?(error)
      names = Config.ignored_exceptions
      return false if names.empty?

      error.class.ancestors.any? { |ancestor| names.include?(ancestor.name) }
    rescue StandardError
      false
    end

    def crawler?(context)
      return false unless Config.ignore_crawlers?

      user_agent = user_agent(context)
      !user_agent.nil? && CRAWLER.match?(user_agent)
    rescue StandardError
      false
    end

    # The User-Agent of the request being served, from the controller Rails
    # puts in the context or from the env RequestTracker keeps. nil outside
    # a request (jobs, rake, runner).
    def user_agent(context)
      controller = context[:controller]
      if controller.respond_to?(:request) && controller.request.respond_to?(:user_agent)
        agent = controller.request.user_agent
        return agent if agent
      end

      RequestTracker.current_env&.fetch("HTTP_USER_AGENT", nil)
    rescue StandardError
      nil
    end
  end
end
