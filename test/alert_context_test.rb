# frozen_string_literal: true

require "test_helper"

# What the alert tells besides the error itself: the context the app
# passed, the chain of causes, the failing line of code, the process and
# how many people the error reached.
class AlertContextTest < ErrorSignalTestCase
  Record = Struct.new(:id) do
    def to_key = [ id ]
  end

  # An object whose #inspect carries personal data: only its class may show.
  class Secretive
    def inspect = "#<Secretive email=joao@example.com>"
    def to_s = inspect
  end

  # A controller with Devise's current_user (private here, as some apps make it).
  class AuthController
    def initialize(user = nil, &lookup)
      @user = user
      @lookup = lookup
    end

    def action_name = "show"

    private

    def current_user = @lookup ? @lookup.call : @user
  end

  # An exception whose cause points back to itself.
  class LoopingError < StandardError
    attr_accessor :looped_cause

    def cause = looped_cause
  end

  setup do
    ENV["DISCORD_WEBHOOK_URL"] = WEBHOOK
    ENV["ERROR_SIGNAL_APP_NAME"] = "shop"
  end

  def app_error(message = "boom", klass: RuntimeError, line: "app/services/pay.rb:12:in 'Pay#call'")
    error = klass.new(message)
    error.set_backtrace([ "#{Rails.root}/#{line}", "/usr/lib/ruby/gems/3.4.0/gems/rack-3.1.0/lib/rack/x.rb:1:in 'call'" ])
    error
  end

  # An error raised while rescuing its causes, so Ruby sets each cause: the
  # first message is the outer error, the last the innermost cause. Each level
  # gets a one-line backtrace (app/services/level<n>.rb), so the alert does
  # not depend on where the gems are installed.
  def with_causes(*messages)
    error = nil
    begin
      raise_chain(messages.dup)
    rescue StandardError => e
      error = e
    end
    level = error
    depth = 0
    while level
      level.set_backtrace([ "#{Rails.root}/app/services/level#{depth}.rb:#{depth + 1}:in 'Level#{depth}#call'" ])
      depth += 1
      level = level.cause
    end
    error
  end

  def raise_chain(messages)
    message = messages.shift
    if messages.empty?
      raise KeyError, message
    else
      begin
        raise_chain(messages)
      rescue StandardError
        raise ArgumentError, message
      end
    end
  end

  def context_value(post)
    field_value(post, "Context")
  end

  # ---- context ---------------------------------------------------------------

  test "the context the app passes shows as key: value lines" do
    context = { credit_order_id: 42, capability: :tts, chain: %w[gemini vertex_gemini azure],
                order: Record.new(7), at: Time.utc(2026, 11, 7, 12), retry: true }
    posts = capturing_posts { report(app_error, handled: true, context: context) }

    value = context_value(posts.first)
    assert value.start_with?("```")
    assert_includes value, "credit_order_id: 42"
    assert_includes value, "capability: tts"
    assert_includes value, "chain: gemini, vertex_gemini, azure"
    assert_includes value, "order: AlertContextTest::Record#7"
    assert_includes value, "at: 2026-11-07T12:00:00Z"
    assert_includes value, "retry: true"
  end

  test "what Rails puts in the context stays out of it, and nil values too" do
    context = { controller: Object.new, job: Object.new, request: Object.new, request_id: "req-1",
                rake_task: "db:seed", hint: { x: 1 }, note: nil, order_id: 3 }
    posts = capturing_posts { report(app_error, context: context) }

    value = context_value(posts.first)
    assert_includes value, "order_id: 3"
    %w[controller job request request_id rake_task hint note].each { |key| refute_includes value, "#{key}:" }
  end

  test "tags are flattened and a nested hash gets dotted keys" do
    context = { tags: { ai_provider: "gemini", ai_model: "flash" }, payment: { gateway: "stripe", meta: { deep: 1 } } }
    posts = capturing_posts { report(app_error, context: context) }

    value = context_value(posts.first)
    assert_includes value, "ai_provider: gemini"
    assert_includes value, "ai_model: flash"
    assert_includes value, "payment.gateway: stripe"
    assert_includes value, "payment.meta: Hash"
    refute_includes value, "deep"
  end

  test "an object shows as its class name, never its inspect" do
    posts = capturing_posts { report(app_error, context: { thing: Secretive.new, list: [ 1, Secretive.new ] }) }

    value = context_value(posts.first)
    assert_includes value, "thing: AlertContextTest::Secretive"
    assert_includes value, "list: 1, AlertContextTest::Secretive"
    refute_includes value, "joao"
  end

  test "a key named like a secret shows [FILTERED] whole, and values go through the sanitizer" do
    context = { api_token: "abc def ghi", password: "hunter2", contact: "joao@example.com" }
    posts = capturing_posts { report(app_error, context: context) }

    value = context_value(posts.first)
    assert_includes value, "api_token: [FILTERED]"
    assert_includes value, "password: [FILTERED]"
    refute_includes value, "def ghi"
    refute_includes value, "hunter2"
    assert_includes value, "contact: j•••@example.com"
  end

  test "more keys than the alert shows, or a long value, go whole in the attachment" do
    context = (1..20).to_h { |i| [ "key#{i}", "value #{i}" ] }
    context["long"] = "#{'x' * 300}END"
    posts = capturing_posts { report(app_error, context: context) }

    value = context_value(posts.first)
    assert_includes value, "key15: value 15"
    refute_includes value, "key16:"
    content = posts.first[:attachment][:content]
    assert_includes content, "key20: value 20"
    assert_includes content, "END"
    assert_within_discord_limits posts.first
  end

  test "a context that fits sends no attachment" do
    posts = capturing_posts { report(app_error, context: { order_id: 1 }) }

    assert_nil posts.first[:attachment]
  end

  test "ERROR_SIGNAL_CONTEXT=false leaves the context out" do
    ENV["ERROR_SIGNAL_CONTEXT"] = "false"
    posts = capturing_posts { report(app_error, context: { order_id: 1 }) }

    assert_nil context_value(posts.first)
  end

  test "ErrorSignal.notify shows its context too" do
    posts = capturing_posts { ErrorSignal.notify(app_error, context: { import_id: 9 }) }

    assert_includes context_value(posts.first), "import_id: 9"
  end

  test "the context is in Portuguese with ERROR_SIGNAL_LOCALE=pt-BR" do
    ENV["ERROR_SIGNAL_LOCALE"] = "pt-BR"
    posts = capturing_posts { report(app_error, context: { order_id: 1 }) }

    assert_includes field_value(posts.first, "Contexto"), "order_id: 1"
  end

  test "the context does not change the group" do
    posts = capturing_posts do
      report(app_error, context: { order_id: 1 })
      report(app_error, context: { order_id: 2 })
    end

    assert_equal 2, posts.size
    assert_includes title(posts.last), "2nd time"
    assert_includes context_value(posts.last), "order_id: 2"
  end

  # ---- causes ----------------------------------------------------------------

  test "the cause shows with its class, message and where it was raised" do
    error = with_causes("checkout failed", "connection refused for joao@example.com")
    posts = capturing_posts { report(error) }

    value = field_value(posts.first, "Cause")
    assert_includes value, "KeyError: connection refused for j•••@example.com"
    assert_includes value, "app/services/level1.rb:2"
    refute_includes value, "joao@"
    assert_nil posts.first[:attachment]
  end

  test "up to three causes show; a longer chain goes whole in the attachment" do
    error = with_causes("top", "level 1", "level 2", "level 3", "level 4")
    posts = capturing_posts { report(error) }

    value = field_value(posts.first, "Cause")
    assert_includes value, "level 1"
    assert_includes value, "level 3"
    refute_includes value, "level 4"
    content = posts.first[:attachment][:content]
    assert_includes content, "Cause 4: KeyError"
    assert_includes content, "level 4"
  end

  test "a cause that points back to the error does not loop" do
    error = app_error("outer", klass: LoopingError)
    inner = app_error("inner", klass: LoopingError)
    error.looped_cause = inner
    inner.looped_cause = error

    posts = capturing_posts { report(error) }

    value = field_value(posts.first, "Cause")
    assert_includes value, "inner"
    refute_includes value, "outer"
  end

  test "an error without a cause has no Cause field" do
    posts = capturing_posts { report(app_error) }

    assert_nil field_value(posts.first, "Cause")
  end

  test "the cause does not change the group" do
    with_cause = with_causes("same", "first cause").tap { |e| e.set_backtrace(app_error.backtrace) }
    without = app_error("same", klass: ArgumentError)
    posts = capturing_posts do
      report(with_cause)
      report(without)
    end

    assert_equal 2, posts.size
    assert_includes title(posts.last), "2nd time"
  end

  # ---- code ------------------------------------------------------------------

  test "the failing app line shows with its code, sanitized" do
    error = app_error(line: "test/fixtures/code/checkout.rb:9:in 'Checkout#call'")
    posts = capturing_posts { report(error) }

    value = field_value(posts.first, "Code")
    assert_includes value, "test/fixtures/code/checkout.rb:9"
    assert_includes value, %(gateway.charge!(total, customer: "j•••@example.com"))
    refute_includes value, "joao@"
  end

  test "the attachment has the lines around the failing one" do
    error = app_error("#{'x' * 2000}", line: "test/fixtures/code/checkout.rb:9:in 'Checkout#call'")
    posts = capturing_posts { report(error) }

    content = posts.first[:attachment][:content]
    assert_includes content, "Code (test/fixtures/code/checkout.rb):"
    assert_includes content, "  6  "
    assert_includes content, "> 9      gateway.charge!"
    assert_includes content, "  12  "
    refute_includes content, "  13  "
  end

  test "a file that is gone, or a line past its end, shows no code" do
    missing = capturing_posts { report(app_error(line: "app/services/gone.rb:3:in 'x'")) }
    past = capturing_posts { report(app_error("other", line: "test/fixtures/code/checkout.rb:400:in 'x'")) }

    assert_nil field_value(missing.first, "Code")
    assert_nil field_value(past.first, "Code")
  end

  test "a line outside the app shows no code" do
    error = RuntimeError.new("boom")
    error.set_backtrace([ "/usr/lib/ruby/3.4.0/net/http.rb:10:in 'x'" ])
    posts = capturing_posts { report(error) }

    assert_nil field_value(posts.first, "Code")
  end

  # ---- process ---------------------------------------------------------------

  test "the process comes from DYNO, and ERROR_SIGNAL_PROCESS wins over it" do
    ENV["DYNO"] = "worker.1"
    posts = capturing_posts { report(app_error) }
    assert_equal "worker.1", field_value(posts.first, "Process")

    ENV["ERROR_SIGNAL_PROCESS"] = "jobs-2"
    posts = capturing_posts { report(app_error("other")) }
    assert_equal "jobs-2", field_value(posts.first, "Process")
  end

  test "without either variable there is no Process field" do
    posts = capturing_posts { report(app_error) }

    assert_nil field_value(posts.first, "Process")
  end

  # ---- user ------------------------------------------------------------------

  def user_value(post)
    field_value(post, "User")
  end

  test "the user comes from user_id in the context, and leaves the Context field" do
    posts = capturing_posts { report(app_error, context: { user_id: 42, order_id: 1 }) }

    assert_equal "42", user_value(posts.first)
    refute_includes context_value(posts.first), "user_id"
  end

  test "a user record in the context shows as Class#id" do
    posts = capturing_posts { report(app_error, context: { user: Record.new(7) }) }

    assert_equal "AlertContextTest::Record#7", user_value(posts.first)
    assert_nil context_value(posts.first)
  end

  test "the logged-in user comes from the controller's current_user" do
    posts = capturing_posts { report(app_error, context: { controller: AuthController.new(Record.new(9)) }) }

    assert_equal "AlertContextTest::Record#9", user_value(posts.first)
  end

  test "the logged-in user comes from Current.user (the Rails 8 authentication generator)" do
    current = Class.new { class << self; attr_accessor :user; end }
    current.user = Record.new(5)
    Object.const_set(:Current, current)

    posts = capturing_posts { report(app_error) }

    assert_equal "AlertContextTest::Record#5", user_value(posts.first)
  ensure
    Object.send(:remove_const, :Current) if Object.const_defined?(:Current)
  end

  test "an app with a Current that has no user, or a controller without current_user, has no User field" do
    Object.const_set(:Current, Class.new { class << self; attr_accessor :account; end })

    posts = capturing_posts { report(app_error, context: { controller: Object.new }) }

    assert_equal 1, posts.size
    assert_nil user_value(posts.first)
  ensure
    Object.send(:remove_const, :Current) if Object.const_defined?(:Current)
  end

  test "a visitor without login has no User field" do
    posts = capturing_posts { report(app_error, context: { controller: AuthController.new(nil) }) }

    assert_nil user_value(posts.first)
  end

  test "a current_user that raises leaves the user out and still posts" do
    controller = AuthController.new { raise ActiveRecord::ConnectionNotEstablished, "db down" } if defined?(ActiveRecord)
    controller ||= AuthController.new { raise IOError, "db down" }
    posts = capturing_posts { report(app_error, context: { controller: controller }) }

    assert_equal 1, posts.size
    assert_nil user_value(posts.first)
  end

  test "the same person in a request and in a job counts once" do
    posts = capturing_posts do
      report(app_error, context: { controller: AuthController.new(Record.new(3)) })
      report(app_error, context: { user_id: 3 })
    end

    assert_match(/· 1 person\z/, title(posts.last))
  end

  test "ERROR_SIGNAL_USER=false leaves the user and the people count out" do
    ENV["ERROR_SIGNAL_USER"] = "false"
    posts = capturing_posts do
      report(app_error, context: { controller: AuthController.new(Record.new(1)) })
      report(app_error, context: { user_id: 2 })
    end

    assert_nil user_value(posts.last)
    refute_match(/person|people/, title(posts.last))
    assert_includes context_value(posts.last), "user_id: 2"
  end

  test "the User field is in Portuguese with ERROR_SIGNAL_LOCALE=pt-BR" do
    ENV["ERROR_SIGNAL_LOCALE"] = "pt-BR"
    posts = capturing_posts { report(app_error, context: { user_id: 42 }) }

    assert_equal "42", field_value(posts.first, "Usuário")
  end

  # ---- people ----------------------------------------------------------------

  test "the title counts the people the error reached" do
    posts = capturing_posts do
      [ 1, 2, 1, 3 ].each { |user| report(app_error, context: { user_id: user }) }
    end

    assert_equal 3, posts.size
    refute_includes title(posts.first), "person"
    assert_match(/2nd time in .+ · 2 people\z/, title(posts[1]))
    assert_match(/4th time in .+ · 3 people\z/, title(posts[2]))
  end

  test "the same person again counts once" do
    posts = capturing_posts { 2.times { report(app_error, context: { user_id: 5 }) } }

    assert_match(/· 1 person\z/, title(posts.last))
  end

  test "a user record counts by its id" do
    posts = capturing_posts do
      report(app_error, context: { user: Record.new(1) })
      report(app_error, context: { user: Record.new(2) })
    end

    assert_match(/· 2 people\z/, title(posts.last))
  end

  test "without a user in the context the title has no people" do
    posts = capturing_posts { 2.times { report(app_error) } }

    refute_match(/person|people/, title(posts.last))
  end

  test "past the limit the title says 100+" do
    posts = capturing_posts { (1..128).each { |user| report(app_error, context: { user_id: user }) } }

    assert_match(/128th time in .+ · 100\+ people\z/, title(posts.last))
  end

  test "people are in Portuguese with ERROR_SIGNAL_LOCALE=pt-BR" do
    ENV["ERROR_SIGNAL_LOCALE"] = "pt-BR"
    posts = capturing_posts do
      report(app_error, context: { user_id: 1 })
      report(app_error, context: { user_id: 1 })
      report(app_error, context: { user_id: 2 })
      report(app_error, context: { user_id: 3 })
    end

    assert_match(/· 1 pessoa\z/, title(posts[1]))
    assert_match(/· 3 pessoas\z/, title(posts[2]))
  end

  test "the cache keeps a short hash of the person, not the id" do
    error = app_error
    capturing_posts { report(error, context: { user_id: 987_654 }) }

    id = ErrorSignal::Fingerprint.for(error).id
    stored = Rails.cache.read("error_signal:u:#{id}:0")
    assert_equal 1, stored.size
    assert_match(/\A\h{12}\z/, stored.first)
    refute_includes stored.first, "987654"
  end

  test "a new burst counts people from zero" do
    ENV["ERROR_SIGNAL_GROUPING_WINDOW"] = "60"
    posts = capturing_posts do
      travel_to(Time.utc(2026, 11, 7, 12)) do
        2.times { |i| report(app_error, context: { user_id: i }) }
      end
      travel_to(Time.utc(2026, 11, 7, 13)) do
        2.times { report(app_error, context: { user_id: 9 }) }
      end
    end

    assert_match(/· 2 people\z/, title(posts[1]))
    assert_match(/· 1 person\z/, title(posts[3]))
  end

  test "a cache failure in the people count still posts" do
    posts = capturing_posts do
      stub_class_method(ErrorSignal::Tracker, :track_person, ->(*) { nil }) do
        2.times { report(app_error, context: { user_id: 1 }) }
      end
    end

    assert_equal 2, posts.size
    refute_match(/person|people/, title(posts.last))
  end

  # ---- all at once -----------------------------------------------------------

  test "with every field full the alert stays within Discord's limits" do
    ENV["DYNO"] = "web.1"
    ENV["ERROR_SIGNAL_RELEASE"] = "r" * 100
    error = with_causes("#{'m' * 3000}", *(1..5).map { |i| "cause #{i} #{'c' * 400}" })
    backtrace = (1..10).map { |i| "#{Rails.root}/app/services/#{'s' * 150}#{i}.rb:#{i}:in 'x'" }
    error.set_backtrace([ "#{Rails.root}/test/fixtures/code/checkout.rb:9:in 'Checkout#call'", *backtrace ])
    context = (1..30).to_h { |i| [ "key_#{i}", "v" * 300 ] }

    posts = capturing_posts do
      2.times { report(error, handled: true, context: context.merge(user_id: 1), source: "s" * 200) }
    end

    posts.each { |post| assert_within_discord_limits post }
    assert posts.last[:attachment]
  end
end
