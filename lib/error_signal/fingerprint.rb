# frozen_string_literal: true

module ErrorSignal
  # Groups occurrences of the same error. The fingerprint is a hash of:
  #
  # - the exception class;
  # - the first backtrace line that belongs to the app (the first line at
  #   all when none does), WITHOUT the line number, so a deploy that only
  #   shifts lines keeps the group (and its new/regressed history);
  # - the message with its variable parts replaced by placeholders, so
  #   "Record 123 not found" and "Record 456 not found" are one group.
  #
  # Only the hash leaves this class. The alert shows the original message,
  # sanitized.
  module Fingerprint
    # Long messages (a SQL statement, a JSON dump) are normalized up to here.
    MESSAGE_LIMIT = 1000

    # Quoted text with one of these is data ('cus_9xY2', "Jane Doe"), and is
    # replaced; a short quoted identifier ('name', "index_users_on_email") is
    # kept, because it tells two bugs apart (undefined method 'name' vs
    # undefined method 'email').
    QUOTED = /(?<![\w])(?:'([^'\n]{0,200})'|"([^"\n]{0,200})"|`([^`'\n]{0,200})['`])(?![\w])/
    QUOTED_DATA = /[\d\s@<>\/:]/
    QUOTED_IDENTIFIER_LIMIT = 40

    NORMALIZERS = [
      [ /[\w.+-]+@[\w-]+(?:\.[\w-]+)+/, "<email>" ],
      [ /\b\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\b/, "<uuid>" ],
      [ /\b0x\h+\b/i, "<hex>" ],
      # Long hashes and tokens: 16+ hex digits, or 20+ characters mixing
      # letters and digits.
      [ /\b\h{16,}\b/, "<hash>" ],
      [ /\b(?=[A-Za-z_-]*\d)(?=[\d_-]*[A-Za-z])[A-Za-z0-9_-]{20,}\b/, "<hash>" ]
    ].freeze

    NUMBER = /\d+(?:[.,]\d+)*/

    # "app/models/user.rb:42:in 'User#name'" -> path and method label.
    LINE = /\A(?<path>.+?):\d+(?::in [`'](?<label>.*)')?\z/
    # "block (2 levels) in", "rescue in"... prefixes of the method label.
    LABEL_PREFIX = /\A(?:(?:block|rescue|ensure)(?: \(\d+ levels\))? in )+/
    # Gem versions in a gem path: a gem upgrade keeps the group.
    GEM_VERSION = %r{/gems/([^/]+?)-\d[\w.]*/}

    Result = Struct.new(:id, :exception_class, :message, :location, keyword_init: true)

    module_function

    def for(error)
      exception_class = error.class.name || error.class.to_s
      backtrace = Array(error.backtrace)
      app_line = Text.app_lines(backtrace, 1).first
      line = app_line || Text.relative_path(backtrace.first)
      message = normalize(message_of(error))
      id = ::Digest::SHA256.hexdigest([ exception_class, location_key(line), message ].join("\n"))[0, 16]

      Result.new(id: id, exception_class: exception_class, message: message, location: line.presence)
    end

    def normalize(message)
      text = message.to_s[0, MESSAGE_LIMIT]
      text = NORMALIZERS.reduce(text) { |result, (pattern, placeholder)| result.gsub(pattern, placeholder) }
      text = text.gsub(QUOTED) do |quoted|
        content = $1 || $2 || $3
        data?(content) ? "<q>" : quoted
      end
      text.gsub(NUMBER, "<n>").squish
    end

    def data?(content)
      content.length > QUOTED_IDENTIFIER_LIMIT || QUOTED_DATA.match?(content)
    end

    # The backtrace line without the line number, the class prefix of the
    # method (Ruby 3.4 prints 'User#name', older Rubies `name') and gem
    # versions.
    def location_key(line)
      match = LINE.match(line.to_s)
      return line.to_s unless match

      label = match[:label].to_s.sub(LABEL_PREFIX, "").split(/[#.]/).last
      "#{match[:path].sub(GEM_VERSION, '/gems/\1/')}:#{label}"
    end

    def message_of(error)
      error.message.to_s
    rescue StandardError
      ""
    end
  end
end
