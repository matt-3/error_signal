# frozen_string_literal: true

module ErrorSignal
  # Small text helpers shared by the alert and the reports.
  module Text
    module_function

    def truncate(string, limit)
      s = string.to_s
      s.length > limit ? "#{s[0, limit - 3]}..." : s
    end

    def code_block(text, limit)
      "```\n#{truncate(text, limit)}\n```"
    end

    # Rails.root with a trailing slash, or nil.
    def app_root
      root = Rails.root&.to_s
      root.present? ? "#{root.chomp('/')}/" : nil
    rescue StandardError
      nil
    end

    def relative_path(line)
      root = app_root
      root ? line.to_s.delete_prefix(root) : line.to_s
    end

    # The first `count` backtrace lines that belong to the app: under
    # Rails.root and outside vendor/ (where a bundle installed inside the
    # project lives), relative to the root.
    def app_lines(backtrace, count)
      root = app_root
      return [] if root.nil?

      Array(backtrace)
        .select { |line| line.start_with?(root) && !line.start_with?("#{root}vendor/") }
        .first(count)
        .map { |line| line.delete_prefix(root) }
    rescue StandardError
      []
    end

    # 1st, 2nd, 3rd, 4th, 11th... in English; 1ª, 2ª... in Portuguese ("vez"
    # is feminine). Written here instead of Integer#ordinalize, which goes
    # through the app's I18n setup.
    def ordinal(number, locale)
      return "#{number}ª" if locale == "pt-BR"

      suffix =
        if (11..13).cover?(number % 100) then "th"
        else { 1 => "st", 2 => "nd", 3 => "rd" }.fetch(number % 10, "th")
        end
      "#{number}#{suffix}"
    end

    # "45 s", "12 min", "3 h", "3 h 5 min", "2 d", localized.
    def duration(seconds)
      seconds = [ seconds.to_i, 1 ].max
      if seconds < 60 then ErrorSignal.translate(:seconds, count: seconds)
      elsif seconds < 3600 then ErrorSignal.translate(:minutes, count: seconds / 60)
      elsif seconds < 172_800
        hours, minutes = (seconds / 60).divmod(60)
        minutes.zero? ? ErrorSignal.translate(:hours, count: hours) : ErrorSignal.translate(:hours_minutes, hours: hours, minutes: minutes)
      else ErrorSignal.translate(:days, count: seconds / 86_400)
      end
    end

    # Joins `lines` with newlines keeping the result within `limit`
    # characters: lines that do not fit are dropped and counted in a last
    # "... and N more" line.
    def fit_lines(lines, limit)
      kept = []
      lines.each_with_index do |line, index|
        rest = lines.size - index - 1
        candidate = (kept + [ line ]).join("\n")
        tail = rest.positive? ? "\n#{ErrorSignal.translate(:more, count: rest)}" : ""
        if (candidate + tail).length <= limit
          kept << line
        else
          more = ErrorSignal.translate(:more, count: lines.size - index)
          return truncate((kept + [ more ]).join("\n"), limit)
        end
      end
      truncate(kept.join("\n"), limit)
    end
  end
end
