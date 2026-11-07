# frozen_string_literal: true

require_relative "lib/error_signal/version"

Gem::Specification.new do |spec|
  spec.name = "error_signal"
  spec.version = ErrorSignal::VERSION
  spec.authors = [ "Mateus Santos" ]
  spec.summary = "Sentry-like alerts and daily/weekly error reports for Rails, posted to Discord: free, no service, no database, no personal data."
  spec.description = <<~TEXT.tr("\n", " ").strip
    Error Signal posts the errors a Rails app reports through Rails.error to a Discord
    webhook. It groups them by fingerprint, posts the 1st, 2nd, 4th, 8th... occurrence of a
    burst, marks new and regressed errors, warns on spikes, and sends daily and weekly
    reports. It covers requests, jobs, rake tasks and rails runner, keeps its counts in
    Rails.cache and filters personal data before anything leaves the app. No dependency
    beyond Rails; works with or without Sentry.
  TEXT
  spec.homepage = "https://github.com/matt-3/error_signal"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  # The README images (docs/assets) are for GitHub only: the package stays small.
  spec.files = Dir["lib/**/*.{rb,rake}", "README.md", "README.pt-BR.md", "CONTRIBUTING.md", "CONTRIBUTING.pt-BR.md", "CHANGELOG.md", "LICENSE"]
  spec.require_paths = [ "lib" ]

  spec.add_dependency "activesupport", ">= 7.1", "< 9"
  spec.add_dependency "railties", ">= 7.1", "< 9"
end
