# frozen_string_literal: true

module ErrorSignal
  # Posts payloads to the webhook.
  #
  # Alerts go out from a separate thread with short timeouts, so network
  # latency is never added to a request. Deliberately NOT through Active
  # Job: an error alert must not depend on the job queue being up (if the
  # queue is down, that is exactly when you want to be told).
  #
  # A process that is about to exit (a rake task or `rails runner` that
  # failed) would kill that thread before it posts, so the Railtie registers
  # an at_exit hook that waits for the pending posts, at most FLUSH_TIMEOUT
  # seconds in all.
  #
  # A payload may carry `attachment: { filename:, content: }`, the full text
  # of what the message had to cut: it goes as a file (multipart). If
  # Discord refuses the file, the message is posted again without it.
  module Delivery
    OPEN_TIMEOUT = 2
    READ_TIMEOUT = 3
    FLUSH_TIMEOUT = 5
    USER_AGENT = "error_signal/#{VERSION} (+https://github.com/matt-3/error_signal)"

    @threads = []
    @lock = Mutex.new

    class << self
      def post_async(payload)
        thread = Thread.new do
          post(payload)
        rescue StandardError => e
          ErrorSignal.log_failure("failed to post to Discord", e)
        end
        @lock.synchronize do
          @threads.select!(&:alive?)
          @threads << thread
        end
        thread
      end

      # Posts now, in the calling thread. Returns true on a 2xx.
      def post(payload)
        attachment = payload[:attachment]
        message = payload.except(:attachment)

        response = request(message, attachment)
        return true if response.is_a?(Net::HTTPSuccess)

        # 429 = rate limit (about 30 messages per minute per webhook). The
        # grouping keeps you well below it; not worth logging as our failure.
        return false if response.code == "429"

        if attachment
          ErrorSignal.log_failure("Discord refused the attachment (#{response.code}), posting without it")
          response = request(message, nil)
          return true if response.is_a?(Net::HTTPSuccess)
          return false if response.code == "429"
        end

        ErrorSignal.log_failure("Discord responded #{response.code}: #{response.body.to_s[0, 200]}")
        false
      end

      def request(message, attachment)
        uri = URI.parse(Config.webhook_url.to_s)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == "https")
        http.open_timeout = OPEN_TIMEOUT
        http.read_timeout = READ_TIMEOUT
        http.write_timeout = READ_TIMEOUT

        request = Net::HTTP::Post.new(uri.request_uri, "User-Agent" => USER_AGENT)
        # JSON.generate, not #to_json: Active Support's encoder differs
        # between Rails versions (Rails 7.1 breaks with json 3).
        json = JSON.generate(message)
        if attachment
          file = StringIO.new(attachment[:content].to_s.b)
          request.set_form([ [ "payload_json", json ],
            [ "files[0]", file, { filename: attachment[:filename].to_s, content_type: "text/plain; charset=utf-8" } ] ],
            "multipart/form-data")
        else
          request["Content-Type"] = "application/json"
          request.body = json
        end

        http.request(request)
      end

      # Waits for the posts still in flight, at most `timeout` seconds in all.
      def flush(timeout = FLUSH_TIMEOUT)
        threads = @lock.synchronize { @threads.dup }
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        threads.each do |thread|
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          break unless remaining.positive?

          thread.join(remaining)
        end
        nil
      rescue StandardError
        nil
      end

      # A forked child (a Puma or job worker) starts with no thread of its
      # parent and with a lock nobody can be holding.
      def reset_after_fork!
        @lock = Mutex.new
        @threads = []
      end

      def flush_at_exit!
        return if @flush_at_exit

        @flush_at_exit = true
        at_exit { flush }
      end
    end
  end
end

ActiveSupport::ForkTracker.after_fork { ErrorSignal::Delivery.reset_after_fork! } if defined?(ActiveSupport::ForkTracker)
