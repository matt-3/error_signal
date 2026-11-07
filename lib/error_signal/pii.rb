# frozen_string_literal: true

require_relative "pii/checksums"
require_relative "pii/br"
require_relative "pii/us"
require_relative "pii/uk"
require_relative "pii/in"
require_relative "pii/eu"

module ErrorSignal
  # Country packs of the built-in sanitizer, enabled by name through
  # ERROR_SIGNAL_PII_RULES.
  module PII
    PACKS = { "br" => Br, "us" => Us, "uk" => Uk, "in" => In, "eu" => Eu }.freeze
  end
end
