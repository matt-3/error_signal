# frozen_string_literal: true

module ErrorSignal
  # The object registered in Rails.error (ActiveSupport::ErrorReporter). A class
  # of its own, so an app can silence it the way Rails documents:
  #
  #   Rails.error.disable(ErrorSignal::Subscriber) { ... }
  #   Rails.error.unsubscribe(ErrorSignal::Subscriber)
  class Subscriber
    def report(error, handled:, severity:, context:, source: nil)
      ErrorSignal.report(error, handled: handled, severity: severity, context: context, source: source)
    end
  end
end
