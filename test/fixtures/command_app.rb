# frozen_string_literal: true

# A tiny Rails app run as a separate process by test/capture_test.rb, to see
# what a real `rails runner` or rake run posts before the process exits.
#
#   ruby test/fixtures/command_app.rb runner "raise 'boom'"
#   ruby test/fixtures/command_app.rb rake boom
ENV["RAILS_ENV"] = "test"

require "logger"
require "rails"
require "action_controller/railtie"
require "error_signal"

class CommandApp < Rails::Application
  config.root = File.expand_path("../..", __dir__)
  config.enable_reloading = false
  config.eager_load = false
  config.logger = Logger.new(nil)
  config.cache_store = :memory_store
  config.active_support.cache_format_version = 7.1
  config.secret_key_base = "test"
end
CommandApp.initialize!

case ARGV.shift
when "runner"
  require "rails/command"
  Rails::Command.invoke("runner", ARGV)
when "rake"
  require "rake"
  Rake.application.run([ "-f", File.expand_path("Rakefile", __dir__), *ARGV ])
end
