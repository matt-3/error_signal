# frozen_string_literal: true

module ErrorSignal
  module PII
    # United Kingdom (ERROR_SIGNAL_PII_RULES=uk): National Insurance numbers, with
    # or without spaces (AB 12 34 56 C, AB123456C).
    module Uk
      RULES = [
        [ /(?<!\w)(?!BG|GB|KN|NK|NT|TN|ZZ)[A-CEGHJ-PR-TW-Z][A-CEGHJ-NPR-TW-Z] ?\d{2} ?\d{2} ?\d{2} ?[A-D](?!\w)/i, Sanitizer::LAST4 ]
      ].freeze
    end
  end
end
