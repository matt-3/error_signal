# frozen_string_literal: true

module ErrorSignal
  # Errors that end a rake task or `rails runner`, which Rails.error does not
  # always see.
  #
  # RAKE. Rails does not wrap rake tasks in the executor, so an exception
  # that escapes a task never reaches Rails.error. Both `rake task` and
  # `bin/rails task` run the tasks inside Rake's `standard_exception_handling`,
  # which calls `Rake::Application#display_error_message` exactly once, for
  # the exception that ends the run (not for one a task rescues, not for
  # `abort`/`exit`, which are SystemExit). The Railtie prepends a module to
  # that method when the app loads its tasks: the same hook Sentry uses.
  #
  # RUNNER. Rails 7.1+ runs the runner code inside the executor, which
  # reports what escapes it to Rails.error, so Error Signal already sees it.
  # What it does not see: `rails runner --skip-executor`, and exceptions
  # outside StandardError (LoadError, NotImplementedError). The Railtie's
  # `runner` block (run by Rails only for `rails runner`) registers an
  # at_exit hook that checks `$!`, the exception ending the process.
  #
  # NO DOUBLE REPORT. Error Signal marks every exception it receives, and
  # Rails marks every exception reported to Rails.error. Both hooks skip an
  # exception with either mark, so an error that went through Rails.error
  # (Rails.error.record inside a task, the runner's executor) is posted once.
  #
  # These reports go to Error Signal only, not through Rails.error: other
  # subscribers (Sentry has its own rake integration) keep their behavior.
  # Both hooks wait for the post before the process exits.
  module Capture
    RAKE_SOURCE = "rake.error_signal"
    RUNNER_SOURCE = "runner.error_signal"

    # Prepended to Rake::Application.
    module RakeApplication
      def display_error_message(exception)
        ErrorSignal::Capture.rake_failure(exception, self)
        super
      end
    end

    module_function

    def install_rake_hook
      return unless defined?(::Rake::Application)
      return if ::Rake::Application.ancestors.include?(RakeApplication)

      ::Rake::Application.prepend(RakeApplication)
    end

    def install_runner_hook
      return if @runner_hook

      @runner_hook = true
      at_exit { runner_exit($!) }
    end

    def rake_failure(exception, application = nil)
      return unless capturable?(exception)

      context = { rake_task: rake_task_name(exception, application) }.compact
      ErrorSignal.report(exception, handled: false, severity: :error, context: context, source: RAKE_SOURCE)
      ErrorSignal.flush
    rescue StandardError => e
      ErrorSignal.log_failure("could not report the rake failure", e)
    end

    def runner_exit(exception)
      if capturable?(exception)
        ErrorSignal.report(exception, handled: false, severity: :error, context: {}, source: RUNNER_SOURCE)
      end
      ErrorSignal.flush
    rescue StandardError => e
      ErrorSignal.log_failure("could not report the runner failure", e)
    end

    # An exception that ends the process because of a bug: not a signal,
    # not an exit, and not one Rails.error or Error Signal already saw.
    def capturable?(exception)
      (exception.is_a?(StandardError) || exception.is_a?(ScriptError)) &&
        !ErrorSignal.already_reported?(exception)
    end

    # The task where the exception was raised (Rake records the invocation
    # chain on it), or the tasks given on the command line.
    def rake_task_name(exception, application)
      chain = exception.chain if exception.respond_to?(:chain)
      task = chain.head if chain.respond_to?(:head)
      return task.name.to_s if task.respond_to?(:name)

      application.top_level_tasks.join(" ").presence if application.respond_to?(:top_level_tasks)
    rescue StandardError
      nil
    end
  end
end
