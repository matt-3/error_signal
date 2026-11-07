# frozen_string_literal: true

module ErrorSignal
  # Built-in sanitizer, used unless the app sets its own with
  # `ErrorSignal.sanitizer = ...`. Two layers:
  #
  # - a global layer, always on, for what leaks into exception messages in
  #   any country: e-mails, phone numbers, payment cards (Luhn), IBANs
  #   (mod 97), credentials, tokens and service keys;
  # - country packs, opt-in through ERROR_SIGNAL_PII_RULES (br, us, uk, in, eu),
  #   for national documents whose shape would be too ambiguous to filter
  #   everywhere. One file per pack under pii/.
  #
  # It errs on the side of redaction where the shape is clear, and uses check
  # digits where a shape alone would eat ordinary ids: a 16-digit order id
  # stays, a 16-digit card number goes. Dates, versions, prices and UUIDs stay
  # readable.
  #
  # Personal data is masked in part (ERROR_SIGNAL_MASK=partial, the default),
  # so the alert still tells which record failed: CPF •••.456.789-••, card
  # •••• •••• •••• 4242, j•••@gmail.com. Secrets (passwords, tokens, keys,
  # cookies, long hashes) never are: they always become [FILTERED] whole.
  # ERROR_SIGNAL_MASK=full turns personal data into [FILTERED] too.
  #
  # The rules run in order. The ones that look at a NAME (query strings,
  # `key=value`, `Bearer`) come first, so the value is filtered whole before
  # the shape rules (digits, long tokens) chop it into pieces.
  module Sanitizer
    FILTERED = "[FILTERED]"

    # Partial masks. A bullet, not "*": Discord reads "***" as bold italic.
    module Mask
      DOT = "\u2022"
      ALNUM = /[[:alnum:]]/

      module_function

      def full?
        Config.mask == "full"
      end

      # Keeps the letters and digits whose position (counting only letters
      # and digits) is in one of `ranges`, and the separators; the other
      # letters and digits become dots. `keep("123.456.789-09", 3..8)` is
      # "•••.456.789-••".
      def keep(text, *ranges)
        return FILTERED if full?

        index = -1
        text.gsub(ALNUM) do |char|
          index += 1
          ranges.any? { |range| range.cover?(index) } ? char : DOT
        end
      end

      # The last `count` letters and digits (never more than half of them),
      # plus the first `first` ones: "(••) •••••-5678", "DE•••••6789".
      def last(text, count = 4, first: 0)
        total = text.scan(ALNUM).size
        count = [ count, total / 2 ].min
        keep(text, 0...first, (total - count)...total)
      end

      # The first character of the local part and the whole domain:
      # "j•••@gmail.com". Always three dots, so the length does not leak.
      def email(text)
        return FILTERED if full?

        local, domain = text.split("@", 2)
        "#{local[0]}#{DOT * 3}@#{domain}"
      end
    end

    # Replacement for the rules whose match is masked down to its last four.
    LAST4 = ->(match) { Mask.last(match[0]) }

    # Query-string names whose value is secret. Matched anywhere in the name:
    # `reset_password_token`, `x-api-key`, `oauth_code` and `client_secret`
    # are all caught.
    QUERY_NAME = /(?:password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|key|code|auth|signature|credential|session|cookie)/i

    # `name=value` and `"name": "value"` names whose value is secret.
    PAIR_NAME = /(?:password|passwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|credential|authorization|session)/i

    # A `:` or `=` that is not part of `::` (Ruby constants such as
    # Devise::Token::Error stay readable).
    SEPARATOR = /(?<!:)[:=](?!:)/

    # Values after a sensitive name: a quoted string whole, or a bare word
    # (with its auth scheme, so `Authorization: Bearer x` loses the token).
    PAIR_VALUE = /(?!\[FILTERED\])(?:"[^"\n]*"|'[^'\n]*'|(?:(?:Bearer|Basic|Token|Digest)[ \t]+)?[^\s"'&,;)}\]]+)/

    # Shape rules that need a check digit or a length check take a lambda
    # that receives the MatchData and returns the replacement: the masked
    # text when the check passes, the text itself otherwise.
    def self.when_valid(masker = ->(text) { Mask.last(text) }, &check)
      ->(match) { check.call(match[0]) ? masker.call(match[0]) : match[0] }
    end

    # International phone numbers with a +: keeps dropping trailing groups
    # while the run has more than 15 digits (a phone followed by a date or
    # an id), and filters what is left when it has 8 to 15 digits.
    PLUS_PHONE = lambda do |match|
      text = match[0]
      candidate = text
      candidate = candidate.sub(/[ \t().-]*[^ \t().-]+\z/, "") while PII::Checksums.digits(candidate).length > 15
      digits = PII::Checksums.digits(candidate).length
      (8..15).cover?(digits) ? "#{Mask.last(candidate)}#{text[candidate.length..]}" : text
    end

    # Applied before the country packs: rules that look at a name or at an
    # unmistakable prefix.
    LEADING_RULES = [
      # Discord webhook URLs: the token in the path is the credential.
      [ %r{https?://(?:(?:ptb|canary)\.)?discord(?:app)?\.com/api/webhooks/\d+/[\w-]+}i, FILTERED ],
      # URL query values of sensitive parameters: ?token=abc&page=2 -> ?token=[FILTERED]&page=2
      [ /([?&;][\w.\[\]%-]*#{QUERY_NAME}[\w.\[\]%-]*=)[^&#\s"'<>]+/, "\\1#{FILTERED}" ],
      # Cookie headers: the whole value, every cookie in it.
      [ /\b((?:set-)?cookies?["']?[ \t]*#{SEPARATOR}[ \t]*["']?)(?!\[FILTERED\])[^\r\n"']+/i, "\\1#{FILTERED}" ],
      # name=value and "name": "value" outside URLs: api_key=abc, password: "abc"
      [ /\b([\w.-]*#{PAIR_NAME}[\w.-]*["']?[ \t]*#{SEPARATOR}[ \t]*)#{PAIR_VALUE}/i, "\\1#{FILTERED}" ],
      # Authorization schemes: Bearer abc.def, Basic dXNlcjpwYXNz. Basic only
      # when the credential looks like base64 (an upper-case letter, a digit
      # or padding), so prose like "Basic validation failed" stays readable.
      [ /\b([Bb]earer)[ \t]+[A-Za-z0-9\-._~+\/]{8,}=*/, "\\1 #{FILTERED}" ],
      [ /\b(Basic)[ \t]+(?=[a-z]*[A-Z0-9+\/=])[A-Za-z0-9+\/]{8,}=*/, "\\1 #{FILTERED}" ],
      # JSON Web Tokens
      [ /\beyJ[\w-]+\.[\w-]+\.[\w-]*/, FILTERED ],
      # Service keys with a known prefix: AWS, Stripe, GitHub, Google, Slack.
      [ /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/, FILTERED ],
      [ /\b(?:sk|rk)_(?:live|test)_[0-9A-Za-z]{10,}/, FILTERED ],
      [ /\b(?:ghp|gho|ghs|ghu|ghr)_[A-Za-z0-9]{30,}/, FILTERED ],
      [ /\bgithub_pat_[A-Za-z0-9_]{20,}/, FILTERED ],
      [ /\bAIza[0-9A-Za-z_-]{35}(?![\w-])/, FILTERED ],
      [ /\bxox[bp]-[0-9A-Za-z-]{10,}/, FILTERED ],
      # E-mails
      [ /[\w.+-]+@[\w-]+(?:\.[\w-]+)+/, ->(match) { Mask.email(match[0]) } ],
      # IBAN, checked with mod 97: GB82 WEST 1234 5698 7654 32, DE89370400440532013000.
      # Masked keeping the country and the last four.
      [ /\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){2,7}(?: ?[A-Z0-9]{1,4})?\b/,
        when_valid(->(text) { Mask.last(text, first: 2) }) { |text| PII::Checksums.iban?(text) } ]
    ].freeze

    # Applied after the country packs: generic shapes of digits and tokens.
    TRAILING_RULES = [
      # Payment cards: 13 to 19 digits, optionally grouped, valid under Luhn.
      [ /(?<![\d.])(?:\d[ -]?){12,18}\d(?![\d.])/, when_valid { |text| PII::Checksums.luhn?(text) } ],
      # Phones with a +: +5511912345678, +55 (11) 91234-5678, +44 20 7946 0958
      [ /(?<![\w+])\+\d[\d \t().-]{6,24}\d/, PLUS_PHONE ],
      # Area code in parentheses: (11) 91234-5678, (415) 555-2671
      [ /(?<![\w(])\(\d{2,4}\)[ .-]?\d{3,5}[ .-]?\d{4}(?!\d)/, LAST4 ],
      # North American: 415-555-2671, 415.555.2671
      [ /(?<![\w.-])\d{3}([.-])\d{3}\1\d{4}(?![\w-]|\.\d)/, LAST4 ],
      # Local numbers with a dash before the last four digits, optionally with
      # an area code: 555-2671, 91234-5678, 11 3456-7890. Not a year range.
      [ %r{(?<![\w./:#-])(?!(?:19|20)\d\d-(?:19|20)\d\d\b)(?:\d{2,3} )?\d{3,5}-\d{4}(?![\w/-]|\.\d)}, LAST4 ],
      # Numbers with a trunk prefix 0: 020 7946 0958, 0161 496 0000, 030 1234567, 01 23 45 67 89
      [ %r{(?<![\w./:#-])0\d{1,4} \d{3,4} \d{3,4}(?![\w/-]|\.\d)}, LAST4 ],
      [ %r{(?<![\w./:#-])0\d{2,4}[ /]\d{5,8}(?![\w/-]|\.\d)}, LAST4 ],
      [ %r{(?<![\w./:#-])0\d(?:[ .]\d{2}){4}(?![\w/-]|\.\d)}, LAST4 ],
      # Long hex secrets (SHA digests, API keys): 32 hex digits or more
      [ /(?<![\w-])[0-9a-f]{32,}(?![\w-])/i, FILTERED ],
      # Long base64-like secrets: 32+ characters mixing upper case, lower case
      # and digits. Requiring the mix keeps snake_case and CamelCase names out.
      [ /(?<![\w+\/-])(?=[A-Za-z0-9+_-]*[A-Z])(?=[A-Za-z0-9+_-]*[a-z])(?=[A-Za-z0-9+_-]*\d)[A-Za-z0-9+_-]{32,}={0,2}/, FILTERED ]
    ].freeze

    module_function

    def call(text)
      apply(text.to_s, rules)
    end

    # The global rules with the packs from ERROR_SIGNAL_PII_RULES in between.
    def rules
      packs = Config.pii_rules.flat_map { |name| PII::PACKS.fetch(name)::RULES }
      LEADING_RULES + packs + TRAILING_RULES
    end

    def apply(text, rules)
      rules.reduce(text) do |result, (pattern, replacement)|
        if replacement.respond_to?(:call)
          result.gsub(pattern) { replacement.call(Regexp.last_match) }
        else
          result.gsub(pattern, replacement)
        end
      end
    end
  end
end

require_relative "pii"
