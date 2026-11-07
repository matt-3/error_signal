# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# The CI matrix runs each Rails version through gemfiles/rails_X_Y.gemfile,
# which sets @rails_requirement and evaluates this file. A plain
# `bundle install` gets the newest Rails the gemspec accepts.
rails_requirement = Array(@rails_requirement || [ ">= 7.1", "< 9" ])

gem "activesupport", *rails_requirement
gem "railties", *rails_requirement

gem "minitest", "~> 5.25"
gem "rake", "~> 13.0"
gem "rubocop-rails-omakase", require: false

group :test do
  # The integration tests run a real job through Active Job and the digest job
  # is an Active Job. Not a runtime dependency: the job is defined only when
  # the app loads Active Job. Action Pack already comes with railties.
  gem "activejob", *rails_requirement
end
