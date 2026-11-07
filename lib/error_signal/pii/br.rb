# frozen_string_literal: true

module ErrorSignal
  module PII
    # Brazil (ERROR_SIGNAL_PII_RULES=br): CPF, CNPJ (numeric and the alphanumeric
    # format issued since July 2026) and mobile numbers written without
    # separators. A number with the document's punctuation is filtered as it
    # is; a bare run of digits only when its check digits are valid, so an
    # 11- or 14-digit order id stays readable.
    #
    # Partial masks: the CPF keeps its six middle digits (the government's
    # own masking, •••.456.789-••); the CNPJ keeps six digits of the root
    # and the branch (••.345.678/0001-••), since its last digits are the
    # branch, 0001 for most companies, and check digits.
    module Br
      RULES = [
        # CNPJ: 12.345.678/0001-95, 12345678000195, 12.ABC.345/01DE-35
        [ %r{(?<![\w./-])[0-9A-Z]{2}\.?[0-9A-Z]{3}\.?[0-9A-Z]{3}/?[0-9A-Z]{4}-?\d{2}(?![\w/-])},
          lambda do |match|
            text = match[0]
            numeric_formatted = text.match?(/\A[\d.\/-]+\z/) && text.match?(/[.\/-]/)
            fully_formatted = text.match?(%r{\A[0-9A-Z]{2}\.[0-9A-Z]{3}\.[0-9A-Z]{3}/[0-9A-Z]{4}-\d{2}\z})
            numeric_formatted || fully_formatted || Checksums.cnpj?(text) ? Sanitizer::Mask.keep(text, 2..11) : text
          end ],
        # CPF: 123.456.789-09, 123456789-09, 12345678909
        [ %r{(?<![\w./-])\d{3}\.?\d{3}\.?\d{3}-?\d{2}(?![\w/-])},
          ->(match) { match[0].match?(/[.-]/) || Checksums.cpf?(match[0]) ? Sanitizer::Mask.keep(match[0], 3..8) : match[0] } ],
        # Mobile numbers without separators: 11912345678, 5511912345678
        [ /(?<![\w+])(?:55)?[1-9]{2}9\d{8}(?!\w)/, Sanitizer::LAST4 ]
      ].freeze
    end
  end
end
