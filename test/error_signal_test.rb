# frozen_string_literal: true

require "test_helper"

# Covers Error Signal's GUARANTEES: it runs inside Rails.error, on every
# reported error, so what must not fail is
#   (a) never raising,
#   (b) not notifying without a configured webhook,
#   (c) posting only what matters (severity, ignored sources, 4xx requests),
#   (d) not leaking PII,
#   (e) labels in the configured locale, falling back to English,
#   (f) staying inside Discord's limits.
# Grouping, alerts and reports have their own files.
class ErrorSignalTest < ErrorSignalTestCase
  # Test sanitizer, to check that the configured one is the one used.
  TEST_SANITIZER = ->(text) { text.gsub(/[\w.+-]+@[\w-]+\.[\w.]+/, "[TEST-FILTERED]") }

  # Minimal stand-ins for what Rails puts in the context.
  FakeRequest = Struct.new(:request_id, :params, :headers)
  FakeController = Struct.new(:action_name, :request)
  FakeJob = Struct.new(:job_id, :arguments)

  def error_with_backtrace(lines, klass: RuntimeError, message: "boom")
    error = klass.new(message)
    error.set_backtrace(lines)
    error
  end

  def root
    "#{Rails.root}/"
  end

  # ---- (b) no webhook, does nothing -----------------------------------------

  test "does not post when DISCORD_WEBHOOK_URL is not set" do
    posts = capturing_posts { report(raised) }

    assert_empty posts, "should not post without a configured webhook"
  end

  test "posts an unhandled error when the webhook is set" do
    ENV["DISCORD_WEBHOOK_URL"] = WEBHOOK

    posts = capturing_posts { report(raised) }

    assert_equal 1, posts.size
    assert_equal "error", field_value(posts.first, "Level")
  end

  test "without a webhook nothing is counted either" do
    report(raised)

    assert_nil Rails.cache.read(ErrorSignal::Tracker.state_key(ErrorSignal::Fingerprint.for(raised).id))
  end

  # ---- (a) never raises ------------------------------------------------------

  test "does not raise when the POST fails" do
    ENV["DISCORD_WEBHOOK_URL"] = WEBHOOK

    # The real post_async (the Thread) swallows the exception; flush waits
    # for it, so the failure happens inside the test.
    stub_class_method(ErrorSignal::Delivery, :post, ->(_payload) { raise Errno::ECONNREFUSED }) do
      assert_nothing_raised do
        report(raised)
        ErrorSignal.flush
      end
    end
  end

  test "a forked child (a Puma or job worker) gets a fresh delivery lock" do
    skip "no fork on this platform" unless Process.respond_to?(:fork)
    lock = ErrorSignal::Delivery.instance_variable_get(:@lock)

    pid = fork { exit!(ErrorSignal::Delivery.instance_variable_get(:@lock).equal?(lock) ? 1 : 0) }
    Process.wait(pid)

    assert_equal 0, $?.exitstatus
  end

  test "does not raise when given something that is not an exception" do
    ENV["DISCORD_WEBHOOK_URL"] = WEBHOOK

    posts = capturing_posts do
      assert_nothing_raised do
        report(Object.new)
        report(nil, context: nil)
        ErrorSignal.notify("just a string")
      end
    end

    assert_empty posts
  end

  test "does not raise with an exception that has no backtrace or a nil context" do
    ENV["DISCORD_WEBHOOK_URL"] = WEBHOOK

    posts = capturing_posts do
      assert_nothing_raised { report(RuntimeError.new("never raised"), context: nil) }
    end

    assert_equal 1, posts.size
    refute_includes field_names(posts.first), "Location"
    refute_includes field_names(posts.first), "Backtrace"
  end

  test "does not raise when the context holds unexpected objects" do
    ENV["DISCORD_WEBHOOK_URL"] = WEBHOOK
    exploding = Object.new
    def exploding.action_name = raise("boom")

    posts = capturing_posts do
      assert_nothing_raised { report(raised, context: { controller: exploding, job: Object.new }) }
    end

    assert_equal 1, posts.size
  end

  test "does not raise when the exception's message raises" do
    ENV["DISCORD_WEBHOOK_URL"] = WEBHOOK
    error = raised
    def error.message = raise("broken message")

    posts = capturing_posts { assert_nothing_raised { report(error) } }

    assert_equal 1, posts.size
    assert_equal "_no message_", embed(posts.first)[:description]
  end

  # ---- (c) what is posted ----------------------------------------------------

  # Each case uses a distinct exception CLASS: the fingerprint includes the
  # class, and `raised` always raises from the same line.
  def report_each_severity(handled:)
    { ArgumentError => :info, TypeError => :warning, NameError => :error }.each do |klass, severity|
      report(raised(klass, severity.to_s), handled: handled, severity: severity)
    end
  end

  def posted_levels(posts)
    posts.map { |p| embed(p)[:description][/info|warning|error/] }
  end

  test "by default posts unhandled errors and skips handled warnings and infos" do
    ENV["DISCORD_WEBHOOK_URL"] = WEBHOOK

    posts = capturing_posts do
      report(raised(ArgumentError, "unhandled"), handled: false, severity: :error)
      report(raised(TypeError, "handled warning"), handled: true, severity: :warning)
      report(raised(NameError, "handled info"), handled: true, severity: :info)
    end

    assert_equal 1, posts.size
    assert_includes title(posts.first), "ArgumentError"
  end

  test "by default posts a handled error the app reports with severity error" do
    ENV["DISCORD_WEBHOOK_URL"] = WEBHOOK

    posts = capturing_posts { report(raised, handled: true, severity: :error) }

    assert_equal 1, posts.size
    assert_equal "error (handled)", field_value(posts.first, "Level")
  end

  test "ERROR_SIGNAL_MIN_LEVEL=warning adds warnings but not infos" do
    ENV["DISCORD_WEBHOOK_URL"] = WEBHOOK
    ENV["ERROR_SIGNAL_MIN_LEVEL"] = "warning"

    posts = capturing_posts { report_each_severity(handled: true) }

    assert_equal %w[warning error], posted_levels(posts)
  end

  test "ERROR_SIGNAL_MIN_LEVEL=info posts every severity" do
    ENV["DISCORD_WEBHOOK_URL"] = WEBHOOK
    ENV["ERROR_SIGNAL_MIN_LEVEL"] = "info"

    posts = capturing_posts { report_each_severity(handled: true) }

    assert_equal %w[info warning error], posted_levels(posts)
  end

  test "ERROR_SIGNAL_MIN_LEVEL accepts debug as info and fatal as error" do
    ENV["ERROR_SIGNAL_MIN_LEVEL"] = "debug"
    assert_equal "info", ErrorSignal.min_level

    ENV["ERROR_SIGNAL_MIN_LEVEL"] = "FATAL"
    assert_equal "error", ErrorSignal.min_level

    ENV["ERROR_SIGNAL_MIN_LEVEL"] = "warn"
    assert_equal "warning", ErrorSignal.min_level
  end

  test "an invalid ERROR_SIGNAL_MIN_LEVEL falls back to the default and does not silence errors" do
    ENV["DISCORD_WEBHOOK_URL"] = WEBHOOK
    ENV["ERROR_SIGNAL_MIN_LEVEL"] = "banana"

    posts = capturing_posts { report_each_severity(handled: false) }

    assert_equal "error", ErrorSignal.min_level
    assert_equal %w[error], posted_levels(posts)
  end

  test "an unknown severity counts as error" do
    ENV["DISCORD_WEBHOOK_URL"] = WEBHOOK

    posts = capturing_posts { report(raised, severity: :catastrophic) }

    assert_equal 1, posts.size
  end

  test "colors the embed by severity" do
    ENV["DISCORD_WEBHOOK_URL"] = WEBHOOK
    ENV["ERROR_SIGNAL_MIN_LEVEL"] = "info"

    posts = capturing_posts { report_each_severity(handled: true) }

    colors = posts.map { |p| embed(p)[:color] }
    alert = ErrorSignal::Alert
    assert_equal [ alert::COLOR_INFO, alert::COLOR_WARNING, alert::COLOR_ERROR ], colors
  end

  test "never posts cache store failures, whatever the minimum level" do
    ENV["DISCORD_WEBHOOK_URL"] = WEBHOOK
    ENV["ERROR_SIGNAL_MIN_LEVEL"] = "info"

    posts = capturing_posts do
      report(raised(ArgumentError), handled: true, severity: :warning, source: "redis_cache_store.active_support")
      report(raised(TypeError), handled: true, severity: :warning, source: "mem_cache_store.active_support")
    end

    assert_empty posts
  end

  test "does not post request errors Rails answers with a 4xx" do
    ENV["DISCORD_WEBHOOK_URL"] = WEBHOOK

    posts = capturing_posts do
      report(raised(ActionController::RoutingError, "no route"), source: ErrorSignal::Filters::REQUEST_SOURCE)
      report(raised(ActionController::ParameterMissing, "param"), source: ErrorSignal::Filters::REQUEST_SOURCE)
    end

    assert_empty posts
  end

  test "the 4xx rule applies only to requests" do
    ENV["DISCORD_WEBHOOK_URL"] = WEBHOOK

    posts = capturing_posts do
      report(raised(ActionController::RoutingError, "inside a job"), source: "application.active_support")
    end

    assert_equal 1, posts.size
  end

  test "shows the source Rails gave the report" do
    ENV["DISCORD_WEBHOOK_URL"] = WEBHOOK

    posts = capturing_posts { report(raised, source: "application.active_support") }

    assert_equal "application.active_support", field_value(posts.first, "Source")
  end

  test "an error reported while posting does not come back in" do
    ENV["DISCORD_WEBHOOK_URL"] = WEBHOOK
    inner_reports = 0
    ErrorSignal.sanitizer = lambda do |text|
      inner_reports += 1
      report(raised(TypeError, "reported from inside")) if inner_reports == 1
      text
    end

    posts = capturing_posts { report(raised(ArgumentError, "outer")) }

    assert_equal 1, posts.size
    assert_includes title(posts.first), "ArgumentError"
  end

  # ---- notify (manual use) ---------------------------------------------------

  test "notify posts an exception directly, marked as handled" do
    ENV["DISCORD_WEBHOOK_URL"] = WEBHOOK

    posts = capturing_posts do
      ErrorSignal.notify(raised, context: { request_id: "abc-123" })
    end

    assert_equal 1, posts.size
    assert_equal "error (handled)", field_value(posts.first, "Level")
    assert_equal "abc-123", field_value(posts.first, "Request ID")
    refute_includes field_names(posts.first), "Source"
  end

  test "notify honors the minimum level" do
    ENV["DISCORD_WEBHOOK_URL"] = WEBHOOK

    posts = capturing_posts { ErrorSignal.notify(raised, severity: :warning) }

    assert_empty posts
  end

  # ---- context ---------------------------------------------------------------

  test "shows controller#action and the request id, and nothing else from the request" do
    ENV["DISCORD_WEBHOOK_URL"] = WEBHOOK
    request = FakeRequest.new("req-42", { "password" => "hunter2", "email" => "x@y.com" }, { "Cookie" => "session=secret-cookie" })
    controller = FakeController.new("update", request)

    posts = capturing_posts { report(raised, context: { controller: controller }) }

    assert_equal "ErrorSignalTest::FakeController#update", field_value(posts.first, "Request")
    assert_equal "req-42", field_value(posts.first, "Request ID")
    body = json(posts.first)
    refute_includes body, "hunter2"
    refute_includes body, "secret-cookie"
  end

  test "shows the job class and id, and not its arguments" do
    ENV["DISCORD_WEBHOOK_URL"] = WEBHOOK
    job = FakeJob.new("job-7", [ "joao@example.com" ])

    posts = capturing_posts { report(raised, context: { job: job }) }

    assert_equal "ErrorSignalTest::FakeJob", field_value(posts.first, "Job")
    assert_equal "job-7", field_value(posts.first, "Job ID")
    refute_includes json(posts.first), "joao@example.com"
  end

  test "the request id goes through the sanitizer" do
    ENV["DISCORD_WEBHOOK_URL"] = WEBHOOK

    # ActionDispatch::RequestId keeps "@" from a client-sent X-Request-Id.
    posts = capturing_posts { report(raised, context: { request_id: "joao@example.com" }) }

    refute_includes json(posts.first), "joao@example.com"
  end

  test "shows the release from ERROR_SIGNAL_RELEASE, SENTRY_RELEASE or GIT_REV" do
    ENV["DISCORD_WEBHOOK_URL"] = WEBHOOK
    ENV["GIT_REV"] = "gitrev1"

    posts = capturing_posts do
      report(raised(ArgumentError))
      ENV["SENTRY_RELEASE"] = "sentry2"
      report(raised(TypeError))
      ENV["ERROR_SIGNAL_RELEASE"] = "signal3"
      report(raised(NameError))
    end

    assert_equal %w[gitrev1 sentry2 signal3], posts.map { |p| field_value(p, "Release") }
  end

  # ---- backtrace -------------------------------------------------------------

  test "the backtrace field shows only app lines, relative to the root, at most five" do
    ENV["DISCORD_WEBHOOK_URL"] = WEBHOOK
    lines = [
      "/usr/local/bundle/gems/activerecord-8.1.0/lib/active_record/core.rb:10:in 'find'",
      "#{root}vendor/bundle/ruby/3.4.0/gems/foo-1.0/lib/foo.rb:2:in 'bar'"
    ] + (1..7).map { |i| "#{root}app/models/user_#{i}.rb:#{i}:in 'step_#{i}'" }

    posts = capturing_posts { report(error_with_backtrace(lines)) }

    backtrace = field_value(posts.first, "Backtrace")
    expected = (1..5).map { |i| "app/models/user_#{i}.rb:#{i}:in 'step_#{i}'" }
    assert_equal "```\n#{expected.join("\n")}\n```", backtrace
    refute_includes backtrace, "gems"
    refute_includes backtrace, root
  end

  test "the location is the first backtrace line, relative to the root" do
    ENV["DISCORD_WEBHOOK_URL"] = WEBHOOK

    posts = capturing_posts do
      report(error_with_backtrace([ "#{root}app/jobs/import_job.rb:3:in 'perform'" ], klass: ArgumentError))
      report(error_with_backtrace([ "/usr/local/bundle/gems/rack-3.2/lib/rack.rb:1:in 'call'" ], klass: TypeError))
    end

    assert_equal "app/jobs/import_job.rb:3:in 'perform'", field_value(posts.first, "Location")
    assert_equal "/usr/local/bundle/gems/rack-3.2/lib/rack.rb:1:in 'call'", field_value(posts.last, "Location")
  end

  test "no backtrace field when no line belongs to the app" do
    ENV["DISCORD_WEBHOOK_URL"] = WEBHOOK

    posts = capturing_posts do
      report(error_with_backtrace([ "/usr/local/bundle/gems/rack-3.2/lib/rack.rb:1:in 'call'" ]))
    end

    refute_includes field_names(posts.first), "Backtrace"
  end

  test "the backtrace stays inside the field limit with long lines" do
    ENV["DISCORD_WEBHOOK_URL"] = WEBHOOK
    lines = (1..5).map { |i| "#{root}app/models/#{'x' * 1000}_#{i}.rb:#{i}:in 'step'" }

    posts = capturing_posts { report(error_with_backtrace(lines)) }

    backtrace = field_value(posts.first, "Backtrace")
    assert_operator backtrace.length, :<=, ErrorSignal::Alert::FIELD_VALUE_LIMIT
    assert backtrace.start_with?("```\n") && backtrace.end_with?("\n```"), "the code block stays closed"
    assert_equal 5, backtrace.lines.count { |l| l.start_with?("app/") }
  end

  test "the backtrace is sanitized" do
    ENV["DISCORD_WEBHOOK_URL"] = WEBHOOK
    lines = [ "#{root}app/mailers/notify.rb:5:in 'deliver_to_joao@example.com'" ]

    posts = capturing_posts { report(error_with_backtrace(lines)) }

    refute_includes field_value(posts.first, "Backtrace"), "joao@example.com"
  end

  test "a real exception raised in the test suite shows this file in the backtrace" do
    ENV["DISCORD_WEBHOOK_URL"] = WEBHOOK

    posts = capturing_posts { report(raised) }

    assert_includes field_value(posts.first, "Backtrace"), "test/test_helper.rb"
    refute_includes field_value(posts.first, "Backtrace"), "minitest"
  end

  # ---- (d) PII ---------------------------------------------------------------

  test "without a configured sanitizer, the built-in one filters the message" do
    ENV["DISCORD_WEBHOOK_URL"] = WEBHOOK
    error = raised(RuntimeError, "user joao@example.com with card 4111 1111 1111 1111 not found")

    posts = capturing_posts { report(error) }

    body = json(posts.first)
    refute_includes body, "joao@example.com"
    refute_includes body, "4111 1111 1111 1111"
    assert_includes body, "j\u2022\u2022\u2022@example.com"
    assert_includes body, "\u2022\u2022\u2022\u2022 \u2022\u2022\u2022\u2022 \u2022\u2022\u2022\u2022 1111"
    assert_equal "built-in", ErrorSignal.sanitizer_name
  end

  test "a sanitizer that raises does not let the text out" do
    ENV["DISCORD_WEBHOOK_URL"] = WEBHOOK
    ErrorSignal.sanitizer = ->(_text) { raise "broken sanitizer" }
    error = raised(RuntimeError, "user joao@example.com not found")

    posts = capturing_posts { report(error) }

    body = json(posts.first)
    refute_includes body, "joao@example.com"
    assert_includes body, "[sanitization failed]"
  end

  test "uses the configured sanitizer on the message, the location and the backtrace" do
    ENV["DISCORD_WEBHOOK_URL"] = WEBHOOK
    ErrorSignal.sanitizer = ->(_text) { "clean" }

    posts = capturing_posts { report(raised) }

    assert_equal "```\nclean\n```", embed(posts.first)[:description]
    assert_equal "clean", field_value(posts.first, "Location")
    assert_equal "```\nclean\n```", field_value(posts.first, "Backtrace")
  end

  test "the sanitizer in use is the configured one, or the built-in one" do
    assert_equal ErrorSignal::Sanitizer, ErrorSignal.sanitizer
    assert_equal "built-in", ErrorSignal.sanitizer_name

    ErrorSignal.sanitizer = TEST_SANITIZER
    assert_equal "[TEST-FILTERED]", ErrorSignal.sanitizer.call("a@b.co")
    assert_equal "custom", ErrorSignal.sanitizer_name

    ErrorSignal.sanitizer = nil
    assert_equal ErrorSignal::Sanitizer, ErrorSignal.sanitizer
  end

  test "a sanitizer another library defines is never picked up on its own" do
    sentry_defined_here = !defined?(::Sentry)
    Object.const_set(:Sentry, Module.new) if sentry_defined_here
    ::Sentry.const_set(:PiiSanitizer, Module.new { def self.sanitize(_text) = "from-sentry" })

    assert_equal "built-in", ErrorSignal.sanitizer_name
    assert_equal "user j\u2022\u2022\u2022@example.com", ErrorSignal.sanitize("user joao@example.com")
  ensure
    ::Sentry.send(:remove_const, :PiiSanitizer) if defined?(::Sentry::PiiSanitizer)
    Object.send(:remove_const, :Sentry) if sentry_defined_here && defined?(::Sentry)
  end

  test "the country packs apply only to the built-in sanitizer" do
    ENV["ERROR_SIGNAL_PII_RULES"] = "br"
    ErrorSignal.sanitizer = ->(text) { text }

    assert_equal "CPF 123.456.789-09", ErrorSignal.sanitize("CPF 123.456.789-09")

    ErrorSignal.sanitizer = nil
    assert_equal "CPF \u2022\u2022\u2022.456.789-\u2022\u2022", ErrorSignal.sanitize("CPF 123.456.789-09")
  end

  # ---- (f) Discord limits ----------------------------------------------------

  test "truncates the title and the footer at Discord's limits" do
    ENV["DISCORD_WEBHOOK_URL"] = WEBHOOK
    ENV["ERROR_SIGNAL_APP_NAME"] = "x" * 400

    posts = capturing_posts { report(raised) }

    assert_operator title(posts.first).length, :<=, 256, "Discord rejects the whole message if the title exceeds 256"
    assert_operator embed(posts.first)[:footer][:text].length, :<=, 2048
  end

  test "truncates the description so it does not exceed the embed limit" do
    ENV["DISCORD_WEBHOOK_URL"] = WEBHOOK

    posts = capturing_posts { report(raised(RuntimeError, "z" * 5000)) }

    assert_operator embed(posts.first)[:description].length, :<=, 4096
  end

  test "every alert stays within Discord's limits, repeated and regressed ones included" do
    ENV["DISCORD_WEBHOOK_URL"] = WEBHOOK
    ENV["ERROR_SIGNAL_APP_NAME"] = "a" * 400
    ENV["ERROR_SIGNAL_RELEASE"] = "r" * 400
    lines = (1..9).map { |i| "#{root}app/models/#{'m' * 900}_#{i}.rb:#{i}:in 'step'" }
    error = error_with_backtrace(lines, message: "z" * 9000)
    context = {
      controller: FakeController.new("a" * 900, FakeRequest.new("i" * 900)),
      job: FakeJob.new("j" * 900),
      rake_task: "t" * 900
    }

    posts = capturing_posts do
      ErrorSignal.sanitizer = ->(text) { text }
      5.times { report(error, context: context, source: "s" * 900) }
      travel(3.days) do
        ENV["ERROR_SIGNAL_RELEASE"] = "x" * 400
        report(error, context: context, source: "s" * 900)
      end
    end

    assert_equal 4, posts.size, "the 1st, 2nd and 4th, then the regression"
    posts.each { |post| assert_within_discord_limits(post) }
    assert_includes field_names(posts.last), "Previously seen"
  end

  test "identifies the app in the message" do
    ENV["DISCORD_WEBHOOK_URL"] = WEBHOOK
    ENV["ERROR_SIGNAL_APP_NAME"] = "my-app"

    posts = capturing_posts { report(raised) }

    assert_includes title(posts.first), "[my-app]"
    assert_equal "Error Signal", posts.first[:username]
    assert_equal "Error Signal #{ErrorSignal::VERSION} · my-app · test", embed(posts.first)[:footer][:text]
  end

  # ---- (e) locale ------------------------------------------------------------

  def full_context
    { controller: FakeController.new("show", FakeRequest.new("req-1")), job: FakeJob.new("job-1"), rake_task: "db:seed" }
  end

  test "labels are in English by default" do
    ENV["DISCORD_WEBHOOK_URL"] = WEBHOOK
    ENV["ERROR_SIGNAL_RELEASE"] = "abc123"

    posts = capturing_posts { report(raised, handled: true, context: full_context, source: "application") }

    assert_equal "en", ErrorSignal.locale
    assert_equal [ "Level", "Source", "Request", "Request ID", "Job", "Job ID", "Task", "Location", "Code", "Backtrace", "Release" ], field_names(posts.first)
    assert_equal "error (handled)", field_value(posts.first, "Level")
  end

  test "ERROR_SIGNAL_LOCALE=pt-BR gives the Portuguese labels" do
    ENV["DISCORD_WEBHOOK_URL"] = WEBHOOK
    ENV["ERROR_SIGNAL_LOCALE"] = "pt-BR"
    ENV["ERROR_SIGNAL_RELEASE"] = "abc123"

    posts = capturing_posts { report(raised, handled: true, context: full_context, source: "application") }

    assert_equal "pt-BR", ErrorSignal.locale
    assert_equal [ "Nível", "Origem", "Requisição", "ID da requisição", "Job", "ID do job", "Task", "Local", "Código", "Backtrace", "Release" ], field_names(posts.first)
    assert_equal "error (tratado)", field_value(posts.first, "Nível")
  end

  test "ERROR_SIGNAL_LOCALE accepts pt-BR spelling variants" do
    %w[pt_BR pt-br PT-BR pt].each do |value|
      ENV["ERROR_SIGNAL_LOCALE"] = value
      assert_equal "pt-BR", ErrorSignal.locale, "#{value.inspect} should resolve to pt-BR"
    end
  end

  test "an unknown ERROR_SIGNAL_LOCALE falls back to English" do
    ENV["DISCORD_WEBHOOK_URL"] = WEBHOOK
    ENV["ERROR_SIGNAL_LOCALE"] = "klingon"

    posts = capturing_posts do
      assert_nothing_raised { report(raised) }
    end

    assert_equal "en", ErrorSignal.locale
    assert_equal [ "Level", "Source", "Location", "Code", "Backtrace" ], field_names(posts.first)
  end

  test "the sanitization failure marker is localized" do
    ENV["DISCORD_WEBHOOK_URL"] = WEBHOOK
    ENV["ERROR_SIGNAL_LOCALE"] = "pt-BR"
    ErrorSignal.sanitizer = ->(_text) { raise "broken" }
    error = raised(RuntimeError, "usuário joao@exemplo.com não encontrado")

    posts = capturing_posts { report(error) }

    body = json(posts.first)
    refute_includes body, "joao@exemplo.com"
    assert_includes body, "[erro ao sanitizar]"
    refute_includes body, "[sanitization failed]"
  end

  test "every locale defines every message key, with the same placeholders" do
    english = ErrorSignal::MESSAGES.fetch("en")

    ErrorSignal::MESSAGES.each do |locale, messages|
      assert_equal english.keys.sort, messages.keys.sort, "#{locale} is missing or has extra keys"
      messages.each do |key, text|
        assert_equal english[key].scan(/%\{\w+\}/).sort, text.scan(/%\{\w+\}/).sort, "#{locale}.#{key} placeholders"
      end
    end
  end
end
