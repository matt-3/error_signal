# frozen_string_literal: true

module ErrorSignal
  # Rack middleware that keeps the current request's env reachable while the
  # request runs, so Error Signal can read its User-Agent (to skip crawlers)
  # and its request id when Rails reports an error.
  #
  # Rails does not hand the request to Rails.error subscribers: the context
  # has the controller (and through it the request) only for errors raised
  # inside a controller action. Errors raised in a middleware, or reported
  # by ActionDispatch::Executor after the controller is gone, come without
  # it. The Railtie inserts this middleware at the top of the stack, above
  # the Executor that reports, so the env is set for every report made while
  # a request is served.
  #
  # Cost per request: one write and one restore of a fiber/thread-local
  # (ActiveSupport::IsolatedExecutionState, the same storage Rails' own
  # ServerTiming middleware uses). Nothing is copied: the env is only read
  # when an error is reported.
  class RequestTracker
    KEY = :error_signal_rack_env

    def self.current_env
      ActiveSupport::IsolatedExecutionState[KEY]
    end

    def initialize(app)
      @app = app
    end

    def call(env)
      previous = ActiveSupport::IsolatedExecutionState[KEY]
      ActiveSupport::IsolatedExecutionState[KEY] = env
      @app.call(env)
    ensure
      ActiveSupport::IsolatedExecutionState[KEY] = previous
    end
  end
end
