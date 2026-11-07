# frozen_string_literal: true

module ErrorSignal
  # Error Signal's memory, kept in Rails.cache under the
  # "error_signal:" prefix. Per occurrence it costs one read and
  # up to three increments (burst, day and spike counters), plus a few
  # writes when a group starts a burst, shows up for the first time in the
  # day, or its state is due for a refresh (at most once a minute).
  #
  # Keys (each with its own expiry, nothing lives forever):
  #
  #   g:<id>               group state: first seen, last seen, release, burst (30 days)
  #   b:<id>:<burst>       occurrences in the current burst (30 days)
  #   s:<id>:<bucket>      occurrences in a 5-minute bucket, for spikes (10 minutes)
  #   d:<day>:c:<id>       occurrences of the group in the day (15 days)
  #   d:<day>:n            groups seen in the day: slot counter (15 days)
  #   d:<day>:i:<slot>     the group id in that slot (15 days)
  #   d:<day>:m:<id>       what the reports show about the group (15 days)
  #   history              14 days of daily summaries, rewritten by every report
  #
  # Increments are atomic in every Rails cache store, so counts hold across
  # processes. Reads and writes of the group state are not, and the design
  # tolerates that: two processes that see a group go quiet at the same time
  # derive the same burst id from the state they read, and the counter tells
  # them apart (one gets the 1st, the other the 2nd occurrence).
  #
  # Any cache failure degrades to "post": an alert duplicated is better than
  # an alert lost.
  module Tracker
    PREFIX = "error_signal"
    HISTORY_KEY = "#{PREFIX}:history"

    STATE_TTL = 30.days
    DAY_TTL = 15.days
    SPIKE_WINDOW = 5.minutes
    REGRESSION_QUIET = 1.day
    MAX_GROUPS_PER_DAY = 1000
    # The group state is rewritten at most this often while the group keeps
    # occurring (or a tenth of the grouping window, if shorter).
    REFRESH_LIMIT = 60

    SAMPLE_LIMIT = 150

    Occurrence = Struct.new(:post, :count, :started_at, :new_group, :regressed,
      :previous_seen_at, :previous_release, :spike, keyword_init: true) do
      # The cache did not answer: post, without markers or counts.
      def degraded?
        count.nil?
      end
    end

    DEGRADED = Occurrence.new(post: true, count: nil, new_group: false, regressed: false, spike: false).freeze

    MessageOccurrence = Struct.new(:post, :count, :started_at, keyword_init: true)

    module_function

    # Counts one ErrorSignal.message with this `key` (its text, or the key
    # given) and tells whether it is posted: the 1st, 2nd, 4th, 8th... in a
    # window of ERROR_SIGNAL_GROUPING_WINDOW that starts at the first one.
    # Messages are not indexed for the reports. A cache failure posts.
    def track_message(key, now: Time.now.to_i)
      cache = Rails.cache
      window = Config.grouping_window
      id = ::Digest::SHA256.hexdigest(key.to_s)[0, 16]

      started_at = cache.fetch("#{PREFIX}:m:#{id}", expires_in: window) { now }.to_i
      count = cache.increment("#{PREFIX}:m:#{id}:#{started_at}", 1, expires_in: window)
      return MessageOccurrence.new(post: true) unless count.is_a?(Integer) && count.positive?

      MessageOccurrence.new(post: power_of_two?(count), count: count, started_at: started_at)
    rescue StandardError => e
      ErrorSignal.log_failure("message grouping unavailable, posting without it", e)
      MessageOccurrence.new(post: true)
    end

    # Records one occurrence of the group `fingerprint` and tells whether it
    # is posted, with its count in the burst, and whether it is new,
    # regressed or crosses the spike threshold.
    def track(fingerprint, now: Time.now.to_i)
      cache = Rails.cache
      id = fingerprint.id
      window = Config.grouping_window
      release = Config.release

      state = cache.read(state_key(id))
      state = nil unless state.is_a?(Hash)
      last_seen = state && state["l"].to_i

      new_group = state.nil?
      quiet = new_group || state["b"].nil? || now - last_seen > window
      regressed = !new_group && quiet && regression?(state, release, now)

      # A new burst is named after the last occurrence before the silence
      # (0 for a group never seen), so every process that sees the same
      # silence counts into the same key.
      burst = quiet ? last_seen.to_i : state["b"]
      started_at = quiet ? now : state["s"].to_i

      count = cache.increment(burst_key(id, burst), 1, expires_in: STATE_TTL)
      return DEGRADED unless count.is_a?(Integer) && count.positive?

      count_day(cache, fingerprint, now, regressed ? "regressed" : ("new" if new_group))
      spike = spike?(cache, id, now)
      refresh_state(cache, id, state, now: now, release: release, burst: burst, started_at: started_at, quiet: quiet, window: window)

      first = count == 1
      Occurrence.new(
        post: power_of_two?(count),
        count: count,
        started_at: started_at,
        new_group: new_group && first,
        regressed: regressed && first,
        previous_seen_at: last_seen,
        previous_release: state && state["r"],
        spike: spike
      )
    rescue StandardError => e
      ErrorSignal.log_failure("grouping unavailable, posting without it", e)
      DEGRADED
    end

    # Seen before, quiet for at least a day, and last seen in another release.
    def regression?(state, release, now)
      previous = state["r"]
      release.present? && previous.present? && previous != release && now - state["l"].to_i >= REGRESSION_QUIET.to_i
    end

    def power_of_two?(count)
      count.positive? && (count & (count - 1)).zero?
    end

    def count_day(cache, fingerprint, now, flag)
      day = day_for(now)
      count = cache.increment(day_key(day, "c", fingerprint.id), 1, expires_in: DAY_TTL)
      return unless count == 1

      # First occurrence of the group today: give it a slot in the day's
      # index (an atomic counter, so two processes never take the same slot)
      # and keep what the report will show.
      slot = cache.increment(day_key(day, "n"), 1, expires_in: DAY_TTL)
      return unless slot.is_a?(Integer) && slot <= MAX_GROUPS_PER_DAY

      cache.write(day_key(day, "i", slot), fingerprint.id, expires_in: DAY_TTL)
      cache.write(day_key(day, "m", fingerprint.id), meta_for(fingerprint, flag), expires_in: DAY_TTL)
    end

    # [class, message sample, location, flag, release], sanitized before it
    # is stored: the cache never holds a raw message.
    def meta_for(fingerprint, flag)
      [
        fingerprint.exception_class,
        Text.truncate(ErrorSignal.sanitize(fingerprint.message), SAMPLE_LIMIT),
        Text.truncate(ErrorSignal.sanitize(fingerprint.location), SAMPLE_LIMIT).presence,
        flag,
        Config.release
      ]
    end

    # True only for the occurrence that crosses the threshold, once per
    # 5-minute bucket: the atomic increment hands that exact count to a
    # single process.
    def spike?(cache, id, now)
      threshold = Config.spike_threshold
      return false unless threshold.positive?

      bucket = now / SPIKE_WINDOW.to_i
      cache.increment(spike_key(id, bucket), 1, expires_in: SPIKE_WINDOW * 2) == threshold + 1
    end

    def refresh_state(cache, id, state, now:, release:, burst:, started_at:, quiet:, window:)
      stale = state.nil? || quiet || state["r"] != release || now - state["l"].to_i >= refresh_interval(window)
      return unless stale

      value = { "f" => (state && state["f"]) || now, "l" => now, "r" => release, "b" => burst, "s" => started_at }
      cache.write(state_key(id), value, expires_in: STATE_TTL)
    end

    def refresh_interval(window)
      (window / 10).clamp(1, REFRESH_LIMIT)
    end

    # Ends the current burst of every group seen recently, so the next
    # occurrence posts as the 1st, and clears the spike buckets. Keeps the
    # rest of the group state (first seen, release) and the report data.
    # Finds the groups through the daily indexes, which cover every group
    # with an open burst. Returns how many groups were reset.
    def clear_grouping(now: Time.now.to_i)
      cache = Rails.cache
      days = ((Config.grouping_window / 1.day.to_i) + 2).clamp(2, 15)
      ids = (0...days).flat_map { |offset| day_ids(day_for(now - (offset * 1.day.to_i))) }.uniq
      bucket = now / SPIKE_WINDOW.to_i

      ids.each do |id|
        state = cache.read(state_key(id))
        if state.is_a?(Hash) && !state["b"].nil?
          cache.delete(burst_key(id, state["b"]))
          cache.write(state_key(id), state.merge("b" => nil, "s" => nil), expires_in: STATE_TTL)
        end
        [ bucket, bucket - 1 ].each { |b| cache.delete(spike_key(id, b)) }
      end
      ids.size
    end

    # ---- reading, for the reports ------------------------------------------

    # Group ids indexed on `day`, and the slot counter (which can be above
    # MAX_GROUPS_PER_DAY when the day overflowed).
    def day_ids(day)
      slots = read_counters([ day_key(day, "n") ]).values.first.to_i
      return [] unless slots.positive?

      keys = (1..[ slots, MAX_GROUPS_PER_DAY ].min).map { |slot| day_key(day, "i", slot) }
      Rails.cache.read_multi(*keys).values.compact.uniq
    end

    def day_slots(day)
      read_counters([ day_key(day, "n") ]).values.first.to_i
    end

    # { id => count } for the groups of `day`.
    def day_counts(day, ids)
      keys = ids.index_by { |id| day_key(day, "c", id) }
      read_counters(keys.keys).to_h { |key, count| [ keys.fetch(key), count.to_i ] }
    end

    def day_meta(day, ids)
      keys = ids.index_by { |id| day_key(day, "m", id) }
      Rails.cache.read_multi(*keys.keys).to_h { |key, meta| [ keys.fetch(key), meta ] }
    end

    def states(ids)
      keys = ids.index_by { |id| state_key(id) }
      Rails.cache.read_multi(*keys.keys).to_h { |key, state| [ keys.fetch(key), state ] }
    end

    # Counters written by #increment. Redis and Memcached keep them raw (a
    # plain read would not decode them), the other stores as entries; `raw:
    # true` reads both (the same thing Rails' read_counter does).
    def read_counters(keys)
      return {} if keys.empty?

      Rails.cache.read_multi(*keys, raw: true)
    end

    def day_for(epoch)
      Time.at(epoch).in_time_zone(Config.time_zone).strftime("%Y%m%d")
    end

    def state_key(id)
      "#{PREFIX}:g:#{id}"
    end

    def burst_key(id, burst)
      "#{PREFIX}:b:#{id}:#{burst}"
    end

    def spike_key(id, bucket)
      "#{PREFIX}:s:#{id}:#{bucket}"
    end

    def day_key(day, kind, suffix = nil)
      suffix.nil? ? "#{PREFIX}:d:#{day}:#{kind}" : "#{PREFIX}:d:#{day}:#{kind}:#{suffix}"
    end
  end
end
