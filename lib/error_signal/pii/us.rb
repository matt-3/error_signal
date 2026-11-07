# frozen_string_literal: true

module ErrorSignal
  module PII
    # United States (ERROR_SIGNAL_PII_RULES=us): Social Security numbers and
    # Employer Identification Numbers, written with their separators. Bare
    # 9-digit runs are left alone: too many ordinary ids have that shape.
    module Us
      RULES = [
        # SSN: 123-45-6789 or 123 45 6789 (never 000, 666 or 9xx in the first group)
        [ /(?<![\w-])(?!000|666|9\d\d)\d{3}([- ])(?!00)\d{2}\1(?!0000)\d{4}(?![\w-])/, Sanitizer::LAST4 ],
        # EIN: 12-3456789
        [ /(?<![\w-])\d{2}-\d{7}(?![\w-])/, Sanitizer::LAST4 ]
      ].freeze
    end
  end
end
