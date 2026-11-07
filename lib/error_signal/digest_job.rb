# frozen_string_literal: true

module ErrorSignal
  # Posts the daily or the weekly report. Defined only when the app loads
  # Active Job (the Railtie requires this file from an on_load hook).
  #
  #   ErrorSignal::DigestJob.perform_later("weekly")
  #
  # Never raises: a failure is logged, so a broken report does not become a
  # retried job and an error alert of its own.
  class DigestJob < ::ActiveJob::Base
    queue_as :default

    def perform(period = "daily")
      status, detail = ErrorSignal::Report.deliver(period)
      logger&.info("[ErrorSignal] #{period} report: #{status} (#{detail})")
    end
  end
end
