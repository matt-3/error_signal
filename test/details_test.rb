# frozen_string_literal: true

require "test_helper"

# What does not fit a Discord message (6000 characters) goes in a text file
# attached to it: the alert's whole message and backtrace, a message's whole
# text and fields, every group of a report. Plus the route of the request.
class DetailsTest < ErrorSignalTestCase
  Report = ErrorSignal::Report

  class SharedStore < ActiveSupport::Cache::MemoryStore; end

  setup do
    ENV["DISCORD_WEBHOOK_URL"] = WEBHOOK
    ENV["ERROR_SIGNAL_APP_NAME"] = "shop"
  end

  def app_error(message: "boom", app_lines: 2, gem_lines: 3)
    root = Rails.root.to_s
    lines = (1..app_lines).map { |i| "#{root}/app/services/step#{i}.rb:#{i}:in 'Step#{i}#call'" }
    lines += (1..gem_lines).map { |i| "/usr/lib/ruby/gems/3.4.0/gems/rack-3.1.0/lib/rack/x#{i}.rb:#{i}:in 'call'" }
    error = RuntimeError.new(message)
    error.set_backtrace(lines)
    error
  end

  def attachment(post)
    post[:attachment]
  end

  # ---- alerts ----------------------------------------------------------------

  test "an alert that fits has no attachment" do
    posts = capturing_posts { report(app_error) }

    assert_nil attachment(posts.first)
  end

  test "a long message goes whole, sanitized, in the attachment" do
    message = "#{'x' * 2500} for joao@example.com END"
    posts = capturing_posts { report(app_error(message: message)) }

    file = attachment(posts.first)
    assert_match(/\Ashop-error-\h{16}\.txt\z/, file[:filename])
    assert_includes file[:content], "END"
    assert_includes file[:content], "j•••@example.com"
    refute_includes file[:content], "joao@example.com"
    assert_operator embed(posts.first)[:description].length, :<, message.length
    assert_within_discord_limits posts.first
  end

  test "more app lines than the alert shows send the whole backtrace, gem lines included" do
    posts = capturing_posts { report(app_error(app_lines: 8, gem_lines: 4)) }

    content = attachment(posts.first)[:content]
    assert_includes content, "app/services/step8.rb:8:in 'Step8#call'"
    assert_includes content, "rack-3.1.0/lib/rack/x4.rb"
    refute_includes content, Rails.root.to_s, "paths are relative to the app"
    assert_includes content, "Level: error"
    refute_includes field_value(posts.first, "Backtrace"), "step6.rb"
  end

  # ---- route -----------------------------------------------------------------

  test "the route shows the method and the pattern, never the URL" do
    routes = ActionDispatch::Routing::RouteSet.new
    routes.draw { get "/orders/:id", to: ->(_env) { raise ArgumentError, "order failed" } }
    app = ActionDispatch::Executor.new(routes, ErrorSignalTestApp.executor)

    posts = capturing_posts do
      ErrorSignal::RequestTracker.new(app).call(Rack::MockRequest.env_for("/orders/48213?token=abc"))
    rescue ArgumentError
      nil
    end

    assert_equal "GET /orders/:id", field_value(posts.first, "Route")
    refute_includes json(posts.first), "48213"
  end

  test "a job has no route" do
    job = Struct.new(:job_id, :arguments).new("job-1", [])
    posts = capturing_posts { report(app_error, context: { job: job }) }

    assert_nil field_value(posts.first, "Route")
  end

  # ---- messages --------------------------------------------------------------

  test "a short message has no attachment" do
    posts = capturing_posts { ErrorSignal.message("Backup restored", fields: { "Size" => "2 GB" }) }

    assert_nil attachment(posts.first)
  end

  test "a long message keeps every field and the whole text in the attachment" do
    fields = (1..30).to_h { |i| [ "field #{i}", "value #{i} #{'v' * 500}" ] }
    posts = capturing_posts { ErrorSignal.message("Import report\n#{'line ' * 600}", fields: fields) }

    content = attachment(posts.first)[:content]
    assert_equal "shop-message.txt", attachment(posts.first)[:filename]
    assert_includes content, "field 30: value 30"
    assert_includes content, "Import report"
    assert_within_discord_limits posts.first
  end

  # ---- reports ---------------------------------------------------------------

  def group_error(name)
    error = RuntimeError.new("#{name} failed for joao@example.com")
    error.set_backtrace([ "#{Rails.root}/app/models/#{name}.rb:7:in '#{name.capitalize}#run'" ])
    error
  end

  def daily_post(groups, at:)
    Rails.cache = SharedStore.new
    capturing_posts do
      travel_to(at - 1.day) { groups.times { |i| (i + 1).times { report(group_error("g#{i}")) } } }
    end
    capturing_posts { travel_to(at) { Report.deliver("daily") } }.first
  end

  test "a daily report with more groups than it lists attaches every group" do
    post = daily_post(Report::DAILY_TOP + 3, at: Time.utc(2026, 11, 7, 9))

    file = attachment(post)
    assert_equal "shop-report-2026-11-06.txt", file[:filename]
    (0...(Report::DAILY_TOP + 3)).each { |i| assert_includes file[:content], "app/models/g#{i}.rb" }
    refute_includes file[:content], "joao@example.com"
    assert_includes file[:content], "[New]"
  end

  test "a daily report that lists every group has no attachment" do
    post = daily_post(2, at: Time.utc(2026, 11, 7, 9))

    assert_nil attachment(post)
  end

  test "a weekly report with errors attaches the groups of both weeks" do
    Rails.cache = SharedStore.new
    capturing_posts do
      travel_to(Time.utc(2026, 11, 3, 10)) { 2.times { report(group_error("alpha")) } }
      travel_to(Time.utc(2026, 11, 4, 10)) { report(group_error("beta")) }
    end
    post = capturing_posts { travel_to(Time.utc(2026, 11, 7, 9)) { Report.deliver("weekly") } }.first

    content = attachment(post)[:content]
    assert_includes content, "0 → 2  RuntimeError"
    assert_includes content, "app/models/beta.rb"
  end

  # ---- delivery --------------------------------------------------------------

  def response(code)
    Net::HTTPResponse::CODE_TO_OBJ.fetch(code).new("1.1", code, "")
  end

  test "an attachment Discord refuses is dropped and the message posted again" do
    calls = []
    answers = [ response("413"), response("204") ]
    stub_class_method(ErrorSignal::Delivery, :request, ->(message, attachment) { calls << [ message, attachment ]; answers.shift }) do
      assert ErrorSignal::Delivery.post({ embeds: [ { title: "x" } ], attachment: { filename: "a.txt", content: "y" } })
    end

    assert_equal 2, calls.size
    assert_equal({ filename: "a.txt", content: "y" }, calls.first.last)
    assert_nil calls.last.last
    refute calls.last.first.key?(:attachment)
  end

  test "a rate limit is not retried without the attachment" do
    calls = 0
    stub_class_method(ErrorSignal::Delivery, :request, ->(_message, _attachment) { calls += 1; response("429") }) do
      refute ErrorSignal::Delivery.post({ embeds: [], attachment: { filename: "a.txt", content: "y" } })
    end

    assert_equal 1, calls
  end
end
