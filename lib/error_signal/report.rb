# frozen_string_literal: true

module ErrorSignal
  # The daily and weekly reports (`DigestJob` and `rake error_signal:digest`).
  #
  # The data is what the Tracker counts per group and per day. Days follow
  # the app's time zone (config.time_zone): the daily report covers the
  # previous calendar day, from 00:00 to 24:00, compared with the day before.
  #
  # Every run also rewrites one compact history key with the summaries of the
  # last 14 days (top 20 groups per day, with counts, plus the new and
  # regressed ones). Rewritten at least once a day, it is never older than 24
  # hours: it survives a cache that expires old entries (Solid Cache's
  # max_age of 7 days) and is the newest entry under size eviction. The
  # weekly report is built from it.
  #
  # A report lists the top groups; when the period had more than it shows,
  # the message carries a text file with every group (Delivery).
  module Report
    PERIODS = %w[daily weekly].freeze
    HISTORY_DAYS = 14
    HISTORY_TOP = 20
    HISTORY_TTL = 30.days
    DAILY_TOP = 10
    LIST_LIMIT = 5

    DESCRIPTION_LIMIT = 3500
    FIELD_LIMIT = 800
    SAMPLE_LIMIT = 100

    # Markdown that would break the layout when it comes inside a message.
    MARKDOWN = /([*_~`|\\])/

    module_function

    # Builds and posts the report. Never raises. Returns [status, detail],
    # with status :sent, :disabled, :invalid or :failed.
    def deliver(period = "daily", now: Time.now)
      period = period.to_s.strip.downcase.presence || "daily"
      return [ :invalid, "unknown period #{period.inspect}: use daily or weekly" ] unless PERIODS.include?(period)
      return [ :disabled, disabled_reason ] unless Config.enabled?

      payload = build(period, now: now)
      Delivery.post(payload) ? [ :sent, payload[:embeds].first[:title] ] : [ :failed, "Discord did not accept the message (see the log)" ]
    rescue StandardError => e
      ErrorSignal.log_failure("failed to build the #{period} report", e)
      [ :failed, "#{e.class}: #{e.message}" ]
    end

    def disabled_reason
      return "DISCORD_WEBHOOK_URL is not set" if Config.webhook_url.nil?

      "Rails.env #{Rails.env} is not in ERROR_SIGNAL_ENVIRONMENTS (#{Config.environments.join(', ')})"
    end

    def build(period, now: Time.now)
      history = refresh_history(now)
      period == "weekly" ? weekly(history, now) : daily(history, now)
    end

    # ---- history -----------------------------------------------------------

    # Reads the history, adds the days it lacks from the daily keys still in
    # the cache (always yesterday; older days only if their keys survived),
    # drops what is older than 14 days, and writes it back.
    def refresh_history(now)
      history = read_history
      yesterday = today(now) - 1

      HISTORY_DAYS.times do |offset|
        date = yesterday - offset
        key = date.iso8601
        next if offset.positive? && history["days"].key?(key)

        summary = summarize(date)
        if summary
          history["days"][key] = summary[:day]
          history["groups"].merge!(summary[:groups])
        elsif offset.zero? && !history["days"].key?(key)
          # Nothing indexed for yesterday: no errors (the store notes say
          # when the cache cannot be trusted for that).
          history["days"][key] = empty_day
        end
      end

      prune!(history, yesterday)
      history["at"] = now.to_i
      Rails.cache.write(Tracker::HISTORY_KEY, history, expires_in: HISTORY_TTL)
      history
    end

    def read_history
      history = Rails.cache.read(Tracker::HISTORY_KEY)
      valid = history.is_a?(Hash) && history["days"].is_a?(Hash) && history["groups"].is_a?(Hash)
      valid ? history : { "days" => {}, "groups" => {}, "at" => nil }
    end

    def empty_day
      { "t" => 0, "g" => 0, "top" => [], "new" => [], "reg" => [], "o" => false }
    end

    # The summary of one day, from its daily keys, or nil when the day has
    # none (no errors, or the keys are gone).
    def summarize(date)
      day = date.strftime("%Y%m%d")
      slots = Tracker.day_slots(day)
      return nil unless slots.positive?

      ids = Tracker.day_ids(day)
      counts = Tracker.day_counts(day, ids)
      metas = Tracker.day_meta(day, ids)
      ranked = ids.sort_by { |id| [ -counts[id].to_i, id ] }

      new_ids = ranked.select { |id| flag(metas[id]) == "new" }.first(HISTORY_TOP)
      regressed = ranked.select { |id| flag(metas[id]) == "regressed" }.first(HISTORY_TOP).map { |id| [ id, Array(metas[id])[4] ] }
      top = ranked.first(HISTORY_TOP).map { |id| [ id, counts[id].to_i ] }

      referenced = (top.map(&:first) + new_ids + regressed.map(&:first)).uniq
      groups = referenced.to_h { |id| [ id, group_info(metas[id]) ] }
      day_summary = {
        "t" => counts.values.sum, "g" => ids.size, "top" => top, "new" => new_ids,
        "reg" => regressed, "o" => slots > Tracker::MAX_GROUPS_PER_DAY
      }
      { day: day_summary, groups: groups }
    end

    def flag(meta)
      Array(meta)[3]
    end

    # [class, message sample, location]
    def group_info(meta)
      meta = Array(meta)
      [ meta[0].to_s, meta[1].to_s, meta[2] ]
    end

    def prune!(history, yesterday)
      oldest = (yesterday - (HISTORY_DAYS - 1)).iso8601
      history["days"].select! { |key, _| key >= oldest }
      referenced = history["days"].values.flat_map do |day|
        Array(day["top"]).map(&:first) + Array(day["new"]) + Array(day["reg"]).map(&:first)
      end
      history["groups"].slice!(*referenced.uniq)
    end

    # ---- daily -------------------------------------------------------------

    def daily(history, now)
      yesterday = today(now) - 1
      before = yesterday - 1
      day = history["days"].fetch(yesterday.iso8601, empty_day)
      previous = history["days"][before.iso8601]
      groups = history["groups"]

      lines = []
      if day["t"].to_i.zero?
        lines << t(:no_errors)
      else
        lines << t(:daily_summary, total: day["t"], groups: day["g"])
      end
      lines << comparison(:compared_day, day["t"].to_i, previous && previous["t"].to_i, date: before.iso8601) if previous

      top = Array(day["top"]).first(DAILY_TOP)
      if top.any?
        states = Tracker.states(top.map(&:first))
        lines << "" << "**#{t(:top_groups)}**"
        top.each { |id, count| lines << top_line(groups[id], count, states[id], now) }
      end

      fields = []
      new_lines = Array(day["new"]).map { |id| group_line(groups[id], count_in(day, id)) }
      fields << list_field(:new_groups, new_lines) if new_lines.any?
      regressed_lines = Array(day["reg"]).map do |id, release|
        [ group_line(groups[id], count_in(day, id)), (t(:regressed_in, release: escape(release)) if release.present?) ].compact.join(" ")
      end
      fields << list_field(:regressed_groups, regressed_lines) if regressed_lines.any?
      cut = day["g"].to_i > top.size || !fits?(new_lines, FIELD_LIMIT) || !fits?(regressed_lines, FIELD_LIMIT)

      notes = store_notes
      notes << t(:note_days_missing, days: before.iso8601) if previous.nil?
      notes << t(:note_overflow, max: Tracker::MAX_GROUPS_PER_DAY, date: yesterday.iso8601) if day["o"]
      fields << list_field(:data, notes) if notes.any?

      title = t(:daily_title, date: yesterday.iso8601)
      payload = embed(title, lines, fields, now)
      payload[:attachment] = daily_details(title, yesterday, day, groups) if cut
      payload
    end

    # Every group of the day, from its daily keys; when they are gone, the
    # top groups the history keeps.
    def daily_details(title, date, day, groups)
      key = date.strftime("%Y%m%d")
      ids = Tracker.day_ids(key)
      rows =
        if ids.any?
          counts = Tracker.day_counts(key, ids)
          metas = Tracker.day_meta(key, ids)
          ids.sort_by { |id| [ -counts[id].to_i, id ] }.map do |id|
            meta = Array(metas[id])
            [ counts[id].to_s, group_info(meta), flag(meta), meta[4] ]
          end
        else
          regressed = Array(day["reg"]).to_h
          Array(day["top"]).map do |id, count|
            status = ("new" if Array(day["new"]).include?(id)) || ("regressed" if regressed.key?(id))
            [ count.to_s, groups[id], status, regressed[id] ]
          end
        end

      lines = [ "[#{Config.app_name}] #{title}", plain(t(:daily_summary, total: day["t"].to_i, groups: day["g"].to_i)), "" ]
      rows.each { |count, info, status, release| lines.concat(detail_row(count, info, status, release)) }
      Alert.attachment("report-#{date.iso8601}", lines)
    end

    # "57  NoMethodError: undefined method 'x' for nil  [New]" and the location below it.
    def detail_row(count, info, status = nil, release = nil)
      exception_class, message, location = Array(info)
      line = "#{count.to_s.rjust(6)}  #{exception_class.presence || '?'}"
      line += ": #{ErrorSignal.sanitize(message)}" if message.present?
      line += "  [#{t(:new_groups)}]" if status == "new"
      line += "  [#{t(:regressed_groups)}#{" #{t(:regressed_in, release: release)}" if release.present?}]" if status == "regressed"
      rows = [ line ]
      rows << "        #{ErrorSignal.sanitize(location)}" if location.present?
      rows
    end

    # The text of a localized line without its Markdown.
    def plain(text)
      text.to_s.delete("*")
    end

    def fits?(lines, limit)
      lines.join("\n").length <= limit
    end

    # ---- weekly ------------------------------------------------------------

    def weekly(history, now)
      last = today(now) - 1
      this_week = (0..6).map { |i| last - i }.reverse
      previous_week = (7..13).map { |i| last - i }.reverse
      days = history["days"]
      groups = history["groups"]

      this_total = this_week.sum { |date| days.dig(date.iso8601, "t").to_i }
      previous_total = previous_week.sum { |date| days.dig(date.iso8601, "t").to_i }
      missing = (previous_week + this_week).reject { |date| days.key?(date.iso8601) }
      previous_known = previous_week.any? { |date| days.key?(date.iso8601) }

      lines = [ t(:weekly_summary, total: this_total) ]
      lines << comparison(:compared_week, this_total, previous_total) if previous_known
      per_day = this_week.map { |date| "#{date.strftime('%m-%d')}: #{days.key?(date.iso8601) ? days.dig(date.iso8601, 't') : '?'}" }
      lines << "" << "**#{t(:per_day)}**" << per_day.join(" · ")

      this_counts = group_counts(days, this_week)
      previous_counts = group_counts(days, previous_week)

      grew = (this_counts.keys | previous_counts.keys)
        .map { |id| [ id, this_counts[id].to_i - previous_counts[id].to_i ] }
        .select { |_, delta| delta.positive? }
        .sort_by { |id, delta| [ -delta, id ] }
        .first(LIST_LIMIT)
        .map { |id, _| "#{group_line(groups[id], nil)} #{previous_counts[id].to_i} → #{this_counts[id].to_i}" }

      gone = disappeared(previous_counts, this_counts, this_week.first, now)
        .map { |id| "#{group_line(groups[id], nil)} #{previous_counts[id]} → 0" }

      regressions = this_week.flat_map do |date|
        Array(days.dig(date.iso8601, "reg")).map do |id, release|
          [ date.iso8601, group_line(groups[id], nil), (t(:regressed_in, release: escape(release)) if release.present?) ].compact.join(" ")
        end
      end

      fields = []
      fields << list_field(:grew_most, grew) if grew.any?
      fields << list_field(:disappeared, gone) if gone.any?
      fields << list_field(:regressions_after_deploys, regressions) if regressions.any?

      notes = store_notes
      notes << t(:note_days_missing, days: missing.map(&:iso8601).join(", ")) if missing.any?
      overflow = (previous_week + this_week).select { |date| days.dig(date.iso8601, "o") }
      overflow.each { |date| notes << t(:note_overflow, max: Tracker::MAX_GROUPS_PER_DAY, date: date.iso8601) }
      notes << t(:note_top_only, top: HISTORY_TOP)
      fields << list_field(:data, notes)

      title = t(:weekly_title, from: this_week.first.iso8601, to: last.iso8601)
      payload = embed(title, lines, fields, now)
      if (this_counts.keys | previous_counts.keys).any?
        payload[:attachment] = weekly_details(title, this_counts, previous_counts, groups, this_total, last)
      end
      payload
    end

    # Every group of the two weeks, "previous → this week", from the top
    # lists the history keeps per day. The weekly message lists only what
    # changed most, so it always carries this file when there was an error.
    def weekly_details(title, this_counts, previous_counts, groups, total, last)
      ids = (this_counts.keys | previous_counts.keys).sort_by { |id| [ -this_counts[id].to_i, -previous_counts[id].to_i, id ] }
      lines = [ "[#{Config.app_name}] #{title}", plain(t(:weekly_summary, total: total)), "" ]
      ids.each do |id|
        lines.concat(detail_row("#{previous_counts[id].to_i} → #{this_counts[id].to_i}", groups[id]))
      end
      lines << "" << t(:note_top_only, top: HISTORY_TOP)
      Alert.attachment("report-#{last.iso8601}-weekly", lines)
    end

    # { id => occurrences } summed over the top lists of `dates`.
    def group_counts(days, dates)
      dates.each_with_object(Hash.new(0)) do |date, totals|
        Array(days.dig(date.iso8601, "top")).each { |id, count| totals[id] += count.to_i }
      end
    end

    # Groups of the previous week that did not occur at all this week: absent
    # from this week's top lists AND last seen (group state) before the week
    # started. A group only less frequent is not "gone".
    def disappeared(previous_counts, this_counts, week_start, now)
      candidates = previous_counts.keys - this_counts.keys
      return [] if candidates.empty?

      start = week_start.in_time_zone(Config.time_zone).beginning_of_day.to_i
      states = Tracker.states(candidates)
      candidates
        .select { |id| (state = states[id]).nil? || state["l"].to_i < start }
        .sort_by { |id| [ -previous_counts[id], id ] }
        .first(LIST_LIMIT)
    rescue StandardError
      []
    end

    # ---- rendering -----------------------------------------------------------

    def embed(title, lines, fields, now)
      name = Config.app_name
      embed = {
        title: Text.truncate("[#{name}] #{title}", Alert::TITLE_LIMIT),
        description: Text.fit_lines(lines, DESCRIPTION_LIMIT),
        color: Alert::COLOR_INFO,
        fields: fields,
        footer: Alert.footer(name),
        timestamp: now.utc.iso8601
      }
      Alert.fit_embed!(embed)
      { username: Alert::USERNAME, embeds: [ embed ], allowed_mentions: { parse: [] } }
    end

    def list_field(key, lines)
      { name: t(key), value: Text.fit_lines(lines, FIELD_LIMIT), inline: false }
    end

    # "**57** `NoMethodError` undefined method 'name' for nil" and, below it,
    # "app/models/user.rb:42 · first seen 3 d ago, last seen 2 h ago"
    def top_line(info, count, state, now)
      line = group_line(info, count)
      details = []
      details << escape(info[2]) if info && info[2].present?
      if state.is_a?(Hash)
        details << t(:seen, first: Text.duration(now.to_i - state["f"].to_i), last: Text.duration(now.to_i - state["l"].to_i))
      end
      details.any? ? "#{line}\n  #{details.join(' · ')}" : line
    end

    # "**57** `NoMethodError` undefined method 'name' for nil"
    def group_line(info, count)
      exception_class, message = Array(info)
      text = "`#{escape(exception_class.presence || '?').delete('`')}`"
      text = "**#{count}** #{text}" if count
      message.present? ? "#{text} #{escape(message)}" : text
    end

    def count_in(day, id)
      Array(day["top"]).find { |top_id, _| top_id == id }&.last
    end

    # The samples were sanitized before they were stored; they go through
    # the sanitizer again here, in case it changed since, and lose the
    # Markdown that would break the layout.
    def escape(text)
      Text.truncate(ErrorSignal.sanitize(text), SAMPLE_LIMIT).gsub(MARKDOWN) { "\\#{::Regexp.last_match(1)}" }
    end

    def comparison(key, current, previous, **values)
      if previous.to_i.positive?
        percent = ((current - previous) * 100.0 / previous).round
        t(key, percent: "#{'+' if percent.positive?}#{percent}%", total: previous, **values)
      else
        t(:"#{key}_flat", total: previous.to_i, **values)
      end
    end

    # What the kind of cache store means for the data, for the reports and
    # `error_signal:check`: :none (nothing is kept), :process (each process has
    # its own, lost on restart), :local (one machine's disk), :shared.
    def store_kind(store = Rails.cache)
      return :none if store.nil?

      name = store.class.name.to_s
      if name == "ActiveSupport::Cache::NullStore" then :none
      elsif name == "ActiveSupport::Cache::MemoryStore" then :process
      elsif name == "ActiveSupport::Cache::FileStore" then :local
      else :shared
      end
    end

    def store_notes
      case store_kind
      when :none then [ t(:note_store_none) ]
      when :process then [ t(:note_store_process) ]
      when :local then [ t(:note_store_local) ]
      else []
      end
    end

    def today(now)
      now.in_time_zone(Config.time_zone).to_date
    end

    def t(key, **values)
      ErrorSignal.translate(key, **values)
    end
  end
end
