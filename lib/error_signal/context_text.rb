# frozen_string_literal: true

module ErrorSignal
  # The context the app passed with the error (`Rails.error.report(e,
  # context: { order_id: 42 })`, `Rails.error.set_context`, `notify(e,
  # context:)`) as "key: value" lines for the alert.
  #
  # What Rails itself puts in the context (the controller, the job, the
  # request) is left out: the alert already shows it as Request, Route and
  # Job. A value is shown only as text: a record as "Order#42", any other
  # object as its class name, never its #inspect (which can carry personal
  # data). `tags` (the Sentry convention) is flattened into the other keys.
  # `user_id` and `user` show in the alert's User field instead (Person),
  # unless ERROR_SIGNAL_USER=false.
  # A key named like a secret (password, token, api_key...) shows
  # [FILTERED]; the lines then go through the sanitizer like the rest of the
  # alert.
  module ContextText
    SKIPPED_KEYS = %w[controller job request request_id rake_task hint].freeze
    LIST_ITEMS = 10
    HASH_DEPTH = 2

    module_function

    # [lines, cut]: at most `max_keys` lines, each value within
    # `value_limit` characters; `cut` tells whether something was left out.
    def lines(context, max_keys:, value_limit:)
      pairs = pairs_of(context)
      shown = pairs.first(max_keys).map do |key, value|
        text = Sanitizer::PAIR_NAME.match?(key) ? Sanitizer::FILTERED : value
        "#{key}: #{Text.truncate(text, value_limit)}"
      end
      cut = pairs.size > max_keys || pairs.first(max_keys).any? { |_, value| value.length > value_limit }
      [ shown.map { |line| ErrorSignal.sanitize(line) }, cut ]
    rescue StandardError
      [ [], false ]
    end

    # [[key, value text]], in the order the app gave them.
    def pairs_of(context)
      return [] unless context.respond_to?(:each_pair)

      result = []
      context.each_pair do |key, value|
        name = key.to_s
        next if SKIPPED_KEYS.include?(name)
        next if Person::CONTEXT_KEYS.include?(name) && Config.user?

        if name == "tags" && value.respond_to?(:each_pair)
          value.each_pair { |tag, tag_value| add(result, tag.to_s, tag_value, 1) }
        else
          add(result, name, value, 1)
        end
      end
      result
    end

    def add(result, name, value, depth)
      return if value.nil?

      if value.respond_to?(:each_pair) && !record?(value)
        if depth >= HASH_DEPTH
          result << [ name, value.class.name.to_s ]
        else
          value.each_pair { |key, inner| add(result, "#{name}.#{key}", inner, depth + 1) }
        end
      else
        result << [ name, text_of(value) ]
      end
    end

    def text_of(value)
      case value
      when String then value.tr("\r\n", "  ")
      when Symbol, Numeric, true, false then value.to_s
      when Array
        items = value.first(LIST_ITEMS).map { |item| scalar?(item) || record?(item) ? text_of(item) : item.class.name.to_s }
        rest = value.size - LIST_ITEMS
        items.join(", ") + (rest.positive? ? " (+#{rest})" : "")
      else
        if record?(value) then "#{value.class.name}##{value.id}"
        elsif value.respond_to?(:iso8601) then value.iso8601
        else value.class.name.to_s
        end
      end
    end

    def scalar?(value)
      value.is_a?(String) || value.is_a?(Symbol) || value.is_a?(Numeric) || value == true || value == false
    end

    # An Active Model record (Active Record or anything that has an id and a key).
    def record?(value)
      value.respond_to?(:to_key) && value.respond_to?(:id) && !value.is_a?(Hash)
    end
  end
end
