# frozen_string_literal: true

module ErrorSignal
  module PII
    # India (ERROR_SIGNAL_PII_RULES=in): Aadhaar numbers (12 digits, Verhoeff check
    # digit) and PAN (ABCPE1234F).
    module In
      RULES = [
        [ /(?<![\w-])[2-9]\d{3}([ -]?)\d{4}\1\d{4}(?![\w-])/,
          ->(match) { Checksums.verhoeff?(match[0]) ? Sanitizer::Mask.last(match[0]) : match[0] } ],
        # The fourth letter is the holder type: person, company, trust...
        [ /(?<!\w)[A-Z]{3}[ABCFGHJLPT][A-Z]\d{4}[A-Z](?!\w)/, Sanitizer::LAST4 ]
      ].freeze
    end
  end
end
