# frozen_string_literal: true

module ErrorSignal
  # Builds the Discord payloads for one error: the alert itself and, when a
  # group crosses ERROR_SIGNAL_SPIKE, the separate spike message.
  module Alert
    # Discord limits (embed object limits in the Discord API docs).
    TITLE_LIMIT = 256
    DESCRIPTION_LIMIT = 4096
    FIELD_VALUE_LIMIT = 1024
    EMBED_LIMIT = 6000

    # The webhook message's author. Every message names the app in its title
    # and its footer, so one channel can take several apps.
    USERNAME = "Error Signal"

    MESSAGE_LIMIT = 1800
    BACKTRACE_LINES = 5
    BACKTRACE_LINE_LIMIT = 200

    # The context the app passed: keys and value length in the alert, and
    # in the attachment.
    CONTEXT_KEYS = 15
    CONTEXT_VALUE_LIMIT = 200
    DETAILS_CONTEXT_KEYS = 50
    DETAILS_CONTEXT_VALUE_LIMIT = 1000

    # The chain of causes (error.cause): levels in the alert, and in the
    # attachment, each with its own backtrace there.
    CAUSES = 3
    CAUSE_MESSAGE_LIMIT = 300
    CAUSE_FIELD_LIMIT = 600
    DETAILS_CAUSES = 10
    DETAILS_CAUSE_BACKTRACE_LINES = 50

    # Code lines around the failing app line in the attachment (the alert
    # shows the line alone).
    DETAILS_CODE_AROUND = 3

    # The attachment with the full text, when the message had to cut it.
    DETAILS_TEXT_LIMIT = 100_000
    DETAILS_BACKTRACE_LINES = 200

    COLOR_ERROR   = 0xE74C3C
    COLOR_WARNING = 0xF39C12
    COLOR_INFO    = 0x3498DB
    COLOR_SPIKE   = 0x9B59B6

    module_function

    def build(error, fingerprint:, occurrence:, level:, handled:, context:, source:, person: nil, now: Time.now.to_i)
      name = Config.app_name
      fields, fields_cut = fields_for(error, occurrence, level, handled, context, source, now, person)
      embed = {
        title: Text.truncate(title(name, fingerprint.exception_class, occurrence, now), TITLE_LIMIT),
        description: description_for(error),
        color: color_for(level),
        fields: fields,
        footer: footer(name),
        timestamp: Time.at(now).utc.iso8601
      }
      description_cut = fit_embed!(embed)
      result = payload(embed, mention: occurrence.new_group || occurrence.regressed)
      result[:attachment] = error_details(error, embed, fingerprint, context) if fields_cut || description_cut || cut?(error)
      result
    end

    # The message or the backtrace did not fit the alert: the message is
    # longer than MESSAGE_LIMIT, or the app has more backtrace lines than
    # the alert shows, or one of them is longer than a line of it.
    def cut?(error)
      return true if ErrorSignal.sanitize(Text.truncate(Fingerprint.message_of(error).to_s, DETAILS_TEXT_LIMIT)).length > MESSAGE_LIMIT

      lines = Text.app_lines(error.backtrace, BACKTRACE_LINES + 1)
      lines.size > BACKTRACE_LINES || lines.any? { |line| line.length > BACKTRACE_LINE_LIMIT }
    end

    # A text file with the alert's fields, the whole message, the code
    # around the failing app line, the whole backtrace (gem lines included,
    # up to DETAILS_BACKTRACE_LINES), the context and the chain of causes,
    # all sanitized.
    def error_details(error, embed, fingerprint, context = {})
      lines = [ embed[:title], "" ]
      embed[:fields].each do |f|
        lines << "#{f[:name]}: #{f[:value]}" unless f[:value].start_with?("```")
      end

      message = Text.truncate(Fingerprint.message_of(error).to_s, DETAILS_TEXT_LIMIT)
      lines << "" << "#{t(:message)}:" << ErrorSignal.sanitize(message)

      app_line = Text.app_lines(error.backtrace, 1).first
      code = Text.source_lines(app_line, around: DETAILS_CODE_AROUND)
      if code.any?
        number = app_line[/:(\d+)/, 1].to_i
        text = code.map { |index, line| "#{index == number ? '>' : ' '} #{index}  #{line}" }.join("\n")
        lines << "" << "#{t(:code)} (#{app_line.split(':').first}):" << ErrorSignal.sanitize(text)
      end

      backtrace = Array(error.backtrace).first(DETAILS_BACKTRACE_LINES).map { |line| Text.relative_path(line) }
      lines << "" << "#{t(:backtrace)}:" << ErrorSignal.sanitize(backtrace.join("\n")) if backtrace.any?

      if Config.context?
        context_lines, = ContextText.lines(context, max_keys: DETAILS_CONTEXT_KEYS, value_limit: DETAILS_CONTEXT_VALUE_LIMIT)
        lines << "" << "#{t(:context)}:" << context_lines.join("\n") if context_lines.any?
      end

      causes_of(error, DETAILS_CAUSES).each_with_index do |cause, index|
        lines << "" << "#{t(:cause)} #{index + 1}: #{cause.class.name}"
        lines << ErrorSignal.sanitize(Text.truncate(Fingerprint.message_of(cause).to_s, DETAILS_TEXT_LIMIT))
        trace = Array(cause.backtrace).first(DETAILS_CAUSE_BACKTRACE_LINES).map { |line| Text.relative_path(line) }
        lines << ErrorSignal.sanitize(trace.join("\n")) if trace.any?
      end

      attachment("error-#{fingerprint.id}", lines)
    end

    # error.cause, its cause and so on, up to `limit`, stopping at a loop.
    def causes_of(error, limit)
      chain = []
      seen = [ error ]
      cause = error.cause
      while cause && chain.size < limit && seen.none? { |e| e.equal?(cause) }
        chain << cause
        seen << cause
        cause = cause.cause
      end
      chain
    rescue StandardError
      []
    end

    # { filename:, content: } for Delivery: "<app>-<name>.txt".
    def attachment(name, lines)
      app = Config.app_name.to_s.parameterize.presence || "app"
      { filename: "#{app}-#{name}.txt", content: Text.truncate("#{lines.join("\n")}\n", DETAILS_TEXT_LIMIT) }
    end

    def spike(error, fingerprint:, now: Time.now.to_i)
      name = Config.app_name
      description = t(:spike_description, threshold: Config.spike_threshold, minutes: Tracker::SPIKE_WINDOW.in_minutes.to_i)
      fields = []
      fields << field(:location, Text.truncate(ErrorSignal.sanitize(fingerprint.location), 300)) if fingerprint.location
      release = Config.release
      fields << field(:release, Text.truncate(release, 100), inline: true) if release

      embed = {
        title: Text.truncate("[#{name}] [#{t(:marker_spike)}] #{fingerprint.exception_class}", TITLE_LIMIT),
        description: "#{description}\n#{description_for(error)}",
        color: COLOR_SPIKE,
        fields: fields,
        footer: footer(name),
        timestamp: Time.at(now).utc.iso8601
      }
      fit_embed!(embed)
      payload(embed, mention: true)
    end

    # Fields an ErrorSignal.message carries at most (Discord takes 25).
    MESSAGE_FIELDS = 20

    # An ErrorSignal.message: the first line in the title, the other lines
    # in the description (the whole text when the first line is too long
    # for the title), and the fields.
    # Everything the app passes goes through the sanitizer.
    def message(text, level:, fields:, occurrence:, mention:, now: Time.now.to_i)
      name = Config.app_name
      clean = ErrorSignal.sanitize(text).strip
      first_line = clean.lines.first.to_s.strip
      repeat = ""
      if occurrence.count.to_i >= 2
        ordinal = Text.ordinal(occurrence.count, ErrorSignal.locale)
        repeat = " - #{t(:nth_time, ordinal: ordinal, elapsed: Text.duration(now - occurrence.started_at.to_i))}"
      end

      embed = {
        title: Text.truncate("[#{name}] #{Text.truncate(first_line, 200)}#{repeat}", TITLE_LIMIT),
        color: color_for(level),
        footer: footer(name),
        timestamp: Time.at(now).utc.iso8601
      }
      description = first_line.length > 200 ? clean : clean.lines.drop(1).join.strip
      embed[:description] = Text.truncate(description, MESSAGE_LIMIT) if description.present?
      budget = EMBED_LIMIT - embed[:title].length - embed[:footer][:text].length - embed[:description].to_s.length
      all_fields = (fields || {}).to_h.map { |name, value| [ ErrorSignal.sanitize(name), ErrorSignal.sanitize(value) ] }
      embed[:fields] = message_fields(all_fields, budget)

      result = payload(embed, mention: mention)
      shown = embed[:fields].sum { |f| f[:value].length }
      cut = description.length > MESSAGE_LIMIT || embed[:fields].size < all_fields.size ||
        shown < all_fields.sum { |_, value| value.presence ? value.length : 1 }
      result[:attachment] = message_details(embed[:title], clean, all_fields) if cut
      result
    end

    # The fields in order, each within Discord's limits, until the embed's
    # 6000 characters are used up; the rest goes only to the attachment.
    def message_fields(fields, budget)
      result = []
      fields.first(MESSAGE_FIELDS).each do |name, value|
        name = Text.truncate(name, TITLE_LIMIT).presence || "-"
        room = [ budget - name.length, FIELD_VALUE_LIMIT ].min
        break if room < 20

        value = Text.truncate(value, room).presence || "-"
        budget -= name.length + value.length
        result << { name: name, value: value, inline: true }
      end
      result
    end

    def message_details(title, text, fields)
      lines = [ title, "", text ]
      lines << "" if fields.any?
      fields.each { |name, value| lines << "#{name}: #{value}" }
      attachment("message", lines)
    end

    # `allowed_mentions` is always set: nothing in the message pings anyone
    # except DISCORD_MENTION, on the messages that carry it.
    def payload(embed, mention:)
      payload = { username: USERNAME, embeds: [ embed ], allowed_mentions: { parse: [] } }
      mention_text = Config.mention if mention
      if mention_text
        payload[:content] = mention_text
        payload[:allowed_mentions] = Config.allowed_mentions_for(mention_text)
      end
      payload
    end

    # "[app] [NEW] NoMethodError", "[app] NoMethodError - 8th time in 12 min",
    # "[app] NoMethodError - 8th time in 12 min · 3 people"
    def title(name, exception_class, occurrence, now)
      marker =
        if occurrence.new_group then "[#{t(:marker_new)}] "
        elsif occurrence.regressed then "[#{t(:marker_regressed)}] "
        end
      count = occurrence.count.to_i
      repeat = ""
      if count >= 2
        ordinal = Text.ordinal(count, ErrorSignal.locale)
        repeat = " - #{t(:nth_time, ordinal: ordinal, elapsed: Text.duration(now - occurrence.started_at.to_i))}"
        repeat += " · #{people(occurrence.people)}" if occurrence.people.to_i.positive?
      end
      "[#{name}] #{marker}#{exception_class}#{repeat}"
    end

    # "1 person", "5 people", "100+ people"
    def people(count)
      return t(:people_many, count: "#{Tracker::PEOPLE_LIMIT}+") if count >= Tracker::PEOPLE_LIMIT

      count == 1 ? t(:people_one) : t(:people_many, count: count)
    end

    # The exception message may contain PII (an e-mail in "user not found:
    # x@y.com"): it always goes through the sanitizer.
    def description_for(error)
      message = Fingerprint.message_of(error)
      return t(:no_message) if message.blank?

      Text.code_block(ErrorSignal.sanitize(message), MESSAGE_LIMIT)
    end

    # [fields, cut]: `cut` tells whether the context or the causes did not
    # fit and go whole only in the attachment.
    def fields_for(error, occurrence, level, handled, context, source, now, person = nil)
      cut = false
      fields = [ field(:level, handled ? "#{level} (#{t(:handled)})" : level, inline: true) ]
      fields << field(:source, Text.truncate(source, 100), inline: true) if source.present?

      request, request_id = request_context(context)
      fields << field(:request, Text.truncate(request, 200), inline: true) if request.present?
      route = route_for(context)
      fields << field(:route, Text.truncate(ErrorSignal.sanitize(route), 200), inline: true) if route.present?
      fields << field(:request_id, Text.truncate(ErrorSignal.sanitize(request_id), 100), inline: true) if request_id.present?

      job, job_id = job_context(context)
      fields << field(:job, Text.truncate(job, 200), inline: true) if job.present?
      fields << field(:job_id, Text.truncate(ErrorSignal.sanitize(job_id), 100), inline: true) if job_id.present?

      task = context[:rake_task]
      fields << field(:task, Text.truncate(ErrorSignal.sanitize(task), 200), inline: true) if task.present?
      fields << field(:user, Text.truncate(ErrorSignal.sanitize(person.label), 100), inline: true) if person
      process = Config.process_name
      fields << field(:process, Text.truncate(ErrorSignal.sanitize(process), 100), inline: true) if process

      if Config.context?
        context_lines, context_cut = ContextText.lines(context, max_keys: CONTEXT_KEYS, value_limit: CONTEXT_VALUE_LIMIT)
        if context_lines.any?
          text = Text.fit_lines(context_lines, FIELD_VALUE_LIMIT - 8)
          cut ||= context_cut || text.length < context_lines.join("\n").length
          fields << field(:context, Text.code_block(text, FIELD_VALUE_LIMIT - 8))
        end
      end

      culprit = Array(error.backtrace).first
      fields << field(:location, Text.truncate(ErrorSignal.sanitize(Text.relative_path(culprit)), 300)) if culprit.present?

      app_line = Text.app_lines(error.backtrace, 1).first
      code = Text.source_lines(app_line).first
      if code
        value = "#{app_line.split(':in ').first}\n#{Text.truncate(code[1].strip, BACKTRACE_LINE_LIMIT)}"
        fields << field(:code, Text.code_block(ErrorSignal.sanitize(value), FIELD_VALUE_LIMIT - 8))
      end

      backtrace = Text.app_lines(error.backtrace, BACKTRACE_LINES).map { |line| Text.truncate(line, BACKTRACE_LINE_LIMIT) }
      fields << field(:backtrace, Text.code_block(ErrorSignal.sanitize(backtrace.join("\n")), FIELD_VALUE_LIMIT - 8)) if backtrace.any?

      causes = causes_of(error, CAUSES + 1)
      if causes.any?
        cut ||= causes.size > CAUSES
        text = causes.first(CAUSES).map { |cause| cause_text(cause) }.join("\n")
        cut ||= text.length > CAUSE_FIELD_LIMIT || causes.first(CAUSES).any? { |c| Fingerprint.message_of(c).to_s.length > CAUSE_MESSAGE_LIMIT }
        fields << field(:cause, Text.code_block(text, CAUSE_FIELD_LIMIT))
      end

      release = Config.release
      fields << field(:release, Text.truncate(release, 100), inline: true) if release.present?

      if occurrence.regressed && occurrence.previous_seen_at
        value = t(:previously_value, ago: Text.duration(now - occurrence.previous_seen_at), release: Text.truncate(occurrence.previous_release, 100))
        fields << field(:previously, value, inline: true)
      end

      [ fields, cut ]
    end

    # "PG::ConnectionBad: could not connect" and, on the next line, where it
    # was raised in the app (or its first line, when no line is the app's).
    def cause_text(cause)
      message = Fingerprint.message_of(cause).to_s.tr("\r\n", "  ")
      head = message.empty? ? cause.class.name.to_s : "#{cause.class.name}: #{Text.truncate(message, CAUSE_MESSAGE_LIMIT)}"
      where = Text.app_lines(cause.backtrace, 1).first || Text.relative_path(Array(cause.backtrace).first)
      text = where.present? ? "#{head}\n  #{Text.truncate(where, BACKTRACE_LINE_LIMIT)}" : head
      ErrorSignal.sanitize(text)
    end

    def field(key, value, inline: false)
      { name: t(key), value: value.to_s, inline: inline }
    end

    # "UsersController#show" and the request id, from the controller Rails
    # puts in the context; the request id also from the env RequestTracker
    # keeps, for errors raised outside a controller. Nothing else from the
    # request: no params, no headers, no URL.
    def request_context(context)
      controller = context[:controller]
      request = "#{controller.class.name}##{controller.action_name}" if controller.respond_to?(:action_name)

      request_id = context[:request_id].presence
      request_id ||= controller.request.request_id if controller.respond_to?(:request) && controller.request.respond_to?(:request_id)
      request_id ||= RequestTracker.current_env&.fetch("action_dispatch.request_id", nil) unless context[:job]

      [ request, request_id.to_s.presence ]
    rescue StandardError
      [ nil, nil ]
    end

    # "GET /orders/:id": the method and the route pattern Rails matched
    # (Rails 7.1+), never the URL itself, so no id or query value leaves.
    # nil in a job, outside a request, or when no route matched.
    def route_for(context)
      return nil if context[:job]

      controller = context[:controller]
      request = controller.request if controller.respond_to?(:request)
      if request.nil?
        env = RequestTracker.current_env
        return nil if env.nil? || !defined?(::ActionDispatch::Request)

        request = ::ActionDispatch::Request.new(env)
      end
      return nil unless request.respond_to?(:route_uri_pattern)

      pattern = request.route_uri_pattern.to_s.delete_suffix("(.:format)")
      pattern.empty? ? nil : "#{request.request_method} #{pattern}"
    rescue StandardError
      nil
    end

    # The job class and id, from the job Rails puts in the context.
    def job_context(context)
      job = context[:job]
      return [ nil, nil ] if job.nil?
      return [ job.name, nil ] if job.is_a?(Class)

      [ job.class.name, (job.job_id if job.respond_to?(:job_id)).to_s.presence ]
    rescue StandardError
      [ nil, nil ]
    end

    # "Error Signal 1.0.0 · my-app · production"
    def footer(name)
      { text: Text.truncate("#{USERNAME} #{VERSION} · #{name} · #{Rails.env}", 200) }
    end

    def color_for(level)
      case level
      when "error"   then COLOR_ERROR
      when "warning" then COLOR_WARNING
      else                COLOR_INFO
      end
    end

    # Discord rejects the whole message when the embed passes 6000
    # characters. The fixed limits keep it well below that; this is the
    # last guard, shrinking the description (the longest part) if needed.
    # Returns true when it had to cut.
    def fit_embed!(embed)
      embed[:description] = Text.truncate(embed[:description], DESCRIPTION_LIMIT)
      excess = embed_size(embed) - EMBED_LIMIT
      return false unless excess.positive?

      embed[:description] = Text.truncate(embed[:description], [ embed[:description].length - excess, 20 ].max)
      true
    end

    def embed_size(embed)
      embed[:title].length + embed[:description].to_s.length + embed[:footer][:text].length +
        embed[:fields].sum { |f| f[:name].length + f[:value].length }
    end

    def t(key, **values)
      ErrorSignal.translate(key, **values)
    end
  end
end
