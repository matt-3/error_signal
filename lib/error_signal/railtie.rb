# frozen_string_literal: true

require "rails/railtie"

module ErrorSignal
  # Wires Error Signal into the app. Nothing to call from the app: the
  # Gemfile line and DISCORD_WEBHOOK_URL are enough.
  class Railtie < ::Rails::Railtie
    initializer "error_signal.subscribe" do
      ErrorSignal.subscribe!(Rails.error)
    end

    # At the top of the stack, above ActionDispatch::Executor (which reports
    # request errors), so the request's env is reachable while Rails reports.
    initializer "error_signal.request_tracker" do |app|
      app.middleware.insert_before 0, ErrorSignal::RequestTracker
    end

    initializer "error_signal.flush_at_exit" do
      ErrorSignal::Delivery.flush_at_exit!
    end

    initializer "error_signal.digest_job" do
      ActiveSupport.on_load(:active_job) { require File.expand_path("digest_job", __dir__) }
    end

    rake_tasks do
      ErrorSignal::Capture.install_rake_hook
      load File.expand_path("tasks/error_signal.rake", __dir__)
    end

    runner do
      ErrorSignal::Capture.install_runner_hook
    end
  end
end
