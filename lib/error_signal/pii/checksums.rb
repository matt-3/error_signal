# frozen_string_literal: true

module ErrorSignal
  module PII
    # Check digits that tell a real card, IBAN or document number from a
    # number that only has the same shape (an order id, a timestamp).
    module Checksums
      VERHOEFF_D = [
        [ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 ], [ 1, 2, 3, 4, 0, 6, 7, 8, 9, 5 ],
        [ 2, 3, 4, 0, 1, 7, 8, 9, 5, 6 ], [ 3, 4, 0, 1, 2, 8, 9, 5, 6, 7 ],
        [ 4, 0, 1, 2, 3, 9, 5, 6, 7, 8 ], [ 5, 9, 8, 7, 6, 0, 4, 3, 2, 1 ],
        [ 6, 5, 9, 8, 7, 1, 0, 4, 3, 2 ], [ 7, 6, 5, 9, 8, 2, 1, 0, 4, 3 ],
        [ 8, 7, 6, 5, 9, 3, 2, 1, 0, 4 ], [ 9, 8, 7, 6, 5, 4, 3, 2, 1, 0 ]
      ].freeze
      VERHOEFF_P = [
        [ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 ], [ 1, 5, 7, 6, 2, 8, 3, 0, 9, 4 ],
        [ 5, 8, 0, 3, 7, 9, 6, 1, 4, 2 ], [ 8, 9, 1, 6, 0, 4, 3, 5, 2, 7 ],
        [ 9, 4, 5, 3, 1, 2, 6, 8, 7, 0 ], [ 4, 2, 8, 6, 5, 7, 3, 9, 0, 1 ],
        [ 2, 7, 9, 3, 8, 0, 6, 4, 1, 5 ], [ 7, 0, 4, 6, 9, 1, 3, 2, 5, 8 ]
      ].freeze

      module_function

      def digits(text)
        text.to_s.gsub(/\D/, "")
      end

      # Payment cards.
      def luhn?(number)
        digits = digits(number)
        return false unless (13..19).cover?(digits.length)

        sum = digits.reverse.each_char.with_index.sum do |char, index|
          value = char.to_i
          next value if index.even?

          value *= 2
          value > 9 ? value - 9 : value
        end
        (sum % 10).zero?
      end

      # ISO 13616: move the first four characters to the end, letters become
      # 10..35, and the number mod 97 must be 1.
      def iban?(text)
        iban = text.to_s.delete(" ").upcase
        return false unless iban.match?(/\A[A-Z]{2}\d{2}[A-Z0-9]{11,30}\z/)

        numeric = (iban[4..] + iban[0, 4]).each_char.map { |c| c.ord >= 65 ? (c.ord - 55).to_s : c }.join
        numeric.to_i % 97 == 1
      end

      # Brazil: CPF (11 digits, two mod-11 check digits).
      def cpf?(text)
        digits = digits(text)
        return false unless digits.length == 11 && digits.squeeze.length > 1

        values = digits.chars.map(&:to_i)
        mod11_check(values[0, 9], (2..10).to_a.reverse) == values[9] &&
          mod11_check(values[0, 10], (2..11).to_a.reverse) == values[10]
      end

      # Brazil: CNPJ (14 characters; since July 2026 the first 12 may be
      # letters, which count as their ASCII code minus 48).
      def cnpj?(text)
        chars = text.to_s.upcase.gsub(/[^0-9A-Z]/, "")
        return false unless chars.match?(/\A[0-9A-Z]{12}\d{2}\z/) && chars.squeeze.length > 1

        values = chars.each_char.map { |c| c.ord - 48 }
        first = [ 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2 ]
        mod11_check(values[0, 12], first) == values[12] &&
          mod11_check(values[0, 13], [ 6 ] + first) == values[13]
      end

      def mod11_check(values, weights)
        remainder = values.zip(weights).sum { |v, w| v * w } % 11
        remainder < 2 ? 0 : 11 - remainder
      end

      # India: Aadhaar (12 digits, Verhoeff check digit).
      def verhoeff?(text)
        digits = digits(text)
        return false if digits.empty?

        check = 0
        digits.reverse.each_char.with_index do |char, index|
          check = VERHOEFF_D[check][VERHOEFF_P[index % 8][char.to_i]]
        end
        check.zero?
      end
    end
  end
end
