# frozen_string_literal: true

module ErrorSignal
  module PII
    # European Union (ERROR_SIGNAL_PII_RULES=eu): VAT identification numbers with
    # their country prefix (DE123456789, FR 12 345678901, NL123456789B01).
    # National ids differ too much from country to country to have a safe
    # shared rule, so they are not covered.
    module Eu
      FORMATS = {
        "AT" => "U\\d{8}", "BE" => "[01]\\d{9}", "BG" => "\\d{9,10}", "CY" => "\\d{8}[A-Z]",
        "CZ" => "\\d{8,10}", "DE" => "\\d{9}", "DK" => "\\d{8}", "EE" => "\\d{9}",
        "EL" => "\\d{9}", "ES" => "[A-Z0-9]\\d{7}[A-Z0-9]", "FI" => "\\d{8}",
        "FR" => "[A-HJ-NP-Z0-9]{2} ?\\d{9}", "HR" => "\\d{11}", "HU" => "\\d{8}",
        "IE" => "\\d{7}[A-W][A-I]?|\\d[A-Z+*]\\d{5}[A-W]", "IT" => "\\d{11}",
        "LT" => "\\d{12}|\\d{9}", "LU" => "\\d{8}", "LV" => "\\d{11}", "MT" => "\\d{8}",
        "NL" => "\\d{9}B\\d{2}", "PL" => "\\d{10}", "PT" => "\\d{9}", "RO" => "\\d{6,10}",
        "SE" => "\\d{12}", "SI" => "\\d{8}", "SK" => "\\d{10}", "XI" => "\\d{12}|\\d{9}|GD\\d{3}|HA\\d{3}"
      }.freeze

      VAT = Regexp.new("(?<![\\w-])(?:#{FORMATS.map { |country, format| "#{country} ?(?:#{format})" }.join('|')})(?![\\w-])")

      # Masked keeping the country prefix and the last four: DE•••••6789.
      RULES = [ [ VAT, ->(match) { Sanitizer::Mask.last(match[0], first: 2) } ] ].freeze
    end
  end
end
