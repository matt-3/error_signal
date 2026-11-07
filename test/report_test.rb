# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "open3"

# Daily counters, the daily and weekly reports, the history key that keeps
# them alive, and the reset of the grouping keys.
class ReportTest < ErrorSignalTestCase
  Report = ErrorSignal::Report
  Tracker = ErrorSignal::Tracker

  # A cache store that is not a MemoryStore by class name: what the reports
  # see with Solid Cache or Redis.
  class SharedStore < ActiveSupport::Cache::MemoryStore; end

  setup do
    ENV["DISCORD_WEBHOOK_URL"] = WEBHOOK
    Rails.cache = SharedStore.new
  end

  # One group per name: its own location and message.
  def group(name, klass: RuntimeError, message: nil)
    error = klass.new(message || "#{name} failed for joao@example.com")
    error.set_backtrace([ "#{Rails.root}/app/models/#{name}.rb:7:in '#{name.capitalize}#run'" ])
    error
  end

  def occur(error, times = 1, at:)
    capturing_posts { travel_to(at) { times.times { report(error) } } }
  end

  def digest(period, at:)
    status = nil
    posts = capturing_posts { travel_to(at) { status, = Report.deliver(period) } }
    assert_equal :sent, status
    assert_equal 1, posts.size
    posts.first
  end

  def day(time)
    Tracker.day_for(time.to_i)
  end

  # ---- counters --------------------------------------------------------------

  test "counts each group per day and keeps a sanitized sample for the report" do
    alpha = group("alpha")
    occur(alpha, 3, at: Time.utc(2026, 11, 5, 10))
    occur(group("beta"), 1, at: Time.utc(2026, 11, 5, 11))
    occur(alpha, 2, at: Time.utc(2026, 11, 6, 10))

    ids = Tracker.day_ids(day(Time.utc(2026, 11, 5)))
    assert_equal 2, ids.size
    id = ErrorSignal::Fingerprint.for(alpha).id
    assert_equal({ id => 3 }, Tracker.day_counts(day(Time.utc(2026, 11, 5)), [ id ]))
    assert_equal({ id => 2 }, Tracker.day_counts(day(Time.utc(2026, 11, 6)), [ id ]))

    exception_class, message, location, flag = Tracker.day_meta(day(Time.utc(2026, 11, 5)), [ id ])[id]
    assert_equal "RuntimeError", exception_class
    assert_equal "alpha failed for <email>", message
    assert_equal "app/models/alpha.rb:7:in 'Alpha#run'", location
    assert_equal "new", flag
  end

  test "days follow the app's time zone, not the request's" do
    original = Time.zone_default
    Time.zone_default = ActiveSupport::TimeZone["America/Sao_Paulo"]

    Time.use_zone("Asia/Tokyo") { occur(group("alpha"), at: Time.utc(2026, 11, 7, 1)) }

    assert_equal 1, Tracker.day_ids("20261106").size, "01:00 UTC is still the 6th in Sao Paulo"
    assert_empty Tracker.day_ids("20261107")
  ensure
    Time.zone_default = original
  end

  # ---- daily -----------------------------------------------------------------

  test "the daily report: totals, comparison, top groups, new and regressed" do
    ENV["ERROR_SIGNAL_RELEASE"] = "v1"
    alpha, beta, gamma, rho = %w[alpha beta gamma rho].map { |name| group(name) }
    occur(rho, at: Time.utc(2026, 11, 1, 12))
    occur(alpha, 4, at: Time.utc(2026, 11, 4, 12))
    ENV["ERROR_SIGNAL_RELEASE"] = "v2"
    occur(alpha, 6, at: Time.utc(2026, 11, 5, 10))
    occur(beta, 2, at: Time.utc(2026, 11, 5, 11))
    occur(gamma, at: Time.utc(2026, 11, 5, 12))
    occur(rho, at: Time.utc(2026, 11, 5, 13))

    post = digest("daily", at: Time.utc(2026, 11, 6, 9))

    assert_equal "[errorsignaltestapp] Daily error report: 2026-11-05", title(post)
    description = embed(post)[:description]
    assert_includes description, "**10** errors in **4** groups."
    assert_includes description, "+150% vs the day before (2026-11-04: 4)."
    assert_includes description, "**Top groups**"
    assert_includes description, "**6** `RuntimeError` alpha failed for <email>\n  app/models/alpha.rb:7:in 'Alpha#run' · first seen 45 h ago, last seen 23 h ago"
    assert_operator description.index("alpha failed"), :<, description.index("beta failed")

    assert_includes field_value(post, "New"), "beta failed"
    assert_includes field_value(post, "New"), "gamma failed"
    refute_includes field_value(post, "New"), "alpha failed"
    assert_equal "**1** `RuntimeError` rho failed for <email> in release v2", field_value(post, "Regressed")
    assert_nil field_value(post, "Data"), "a shared store, and the day before is known"

    refute_includes json(post), "joao@example.com"
    assert_equal({ parse: [] }, post[:allowed_mentions])
    assert_within_discord_limits(post)
  end

  test "a day without errors says so" do
    post = digest("daily", at: Time.utc(2026, 11, 6, 9))

    assert_equal "No errors.", embed(post)[:description]
    assert_equal "No data for 2026-11-04.", field_value(post, "Data")
  end

  test "the comparison without errors the day before gives the number without a percentage" do
    digest("daily", at: Time.utc(2026, 11, 5, 9)) # records the 4th as a day without errors
    occur(group("alpha"), at: Time.utc(2026, 11, 5, 10))

    post = digest("daily", at: Time.utc(2026, 11, 6, 9))

    assert_includes embed(post)[:description], "The day before (2026-11-04): 0."
  end

  test "states when the cache store cannot hold the data" do
    { ActiveSupport::Cache::MemoryStore.new => "memory store", ActiveSupport::Cache::NullStore.new => "null store",
      ActiveSupport::Cache::FileStore.new(Dir.mktmpdir) => "file store" }.each do |store, name|
      Rails.cache = store
      post = digest("daily", at: Time.utc(2026, 11, 6, 9))

      assert_includes field_value(post, "Data"), name
    end
  end

  test "the daily report stays within Discord's limits with many long groups" do
    30.times do |i|
      error = group("group#{i}", message: "#{'very long message ' * 30} #{i}")
      error.set_backtrace([ "#{Rails.root}/app/models/#{'deep/' * 40}group#{i}.rb:1:in 'run'" ])
      occur(error, i + 1, at: Time.utc(2026, 11, 5, 10))
    end

    post = digest("daily", at: Time.utc(2026, 11, 6, 9))

    assert_within_discord_limits(post)
    assert_match(/\.\.\. and \d+ more/, field_value(post, "New"))
  end

  test "groups past the daily cap are reported as partial data" do
    stub_const(Tracker, :MAX_GROUPS_PER_DAY, 3) do
      5.times { |i| occur(group("g#{i}"), at: Time.utc(2026, 11, 5, 10)) }

      post = digest("daily", at: Time.utc(2026, 11, 6, 9))

      assert_includes embed(post)[:description], "**3** errors in **3** groups."
      assert_includes field_value(post, "Data"), "More than 3 groups on 2026-11-05"
    end
  end

  test "the daily report in Portuguese" do
    ENV["ERROR_SIGNAL_LOCALE"] = "pt-BR"
    occur(group("alpha"), 2, at: Time.utc(2026, 11, 4, 10))
    occur(group("alpha"), 3, at: Time.utc(2026, 11, 5, 10))
    occur(group("beta"), at: Time.utc(2026, 11, 5, 10))

    post = digest("daily", at: Time.utc(2026, 11, 6, 9))

    assert_equal "[errorsignaltestapp] Relatório diário de erros: 2026-11-05", title(post)
    description = embed(post)[:description]
    assert_includes description, "**4** erros em **2** grupos."
    assert_includes description, "+100% em relação ao dia anterior (2026-11-04: 2)."
    assert_includes description, "**Grupos mais frequentes**"
    assert_includes description, "visto pela primeira vez há 47 h, pela última vez há 23 h"
    assert_includes field_value(post, "Novos"), "beta"
  end

  # ---- weekly ----------------------------------------------------------------

  test "the weekly report: totals and trend, per day, growth, disappeared groups and regressions" do
    ENV["ERROR_SIGNAL_RELEASE"] = "v1"
    alpha, gone, newer, rho = %w[alpha gone newer rho].map { |name| group(name) }
    # Previous week: Oct 24 to Oct 30. This week: Oct 31 to Nov 6.
    occur(rho, at: Time.utc(2026, 10, 24, 12))
    occur(gone, 5, at: Time.utc(2026, 10, 25, 12))
    occur(alpha, 2, at: Time.utc(2026, 10, 26, 12))
    ENV["ERROR_SIGNAL_RELEASE"] = "v2"
    occur(alpha, 10, at: Time.utc(2026, 11, 2, 12))
    occur(newer, 3, at: Time.utc(2026, 11, 3, 12))
    occur(rho, at: Time.utc(2026, 11, 4, 12))
    # Every day is recorded by the daily report, quiet ones included.
    (Date.new(2026, 10, 25)..Date.new(2026, 11, 7)).each { |date| digest("daily", at: date.to_time(:utc) + 9.hours) }

    post = digest("weekly", at: Time.utc(2026, 11, 7, 9, 30))

    assert_equal "[errorsignaltestapp] Weekly error report: 2026-10-31 to 2026-11-06", title(post)
    description = embed(post)[:description]
    assert_includes description, "**14** errors in the last 7 days."
    assert_includes description, "+75% vs the previous 7 days (8)."
    assert_includes description, "10-31: 0 · 11-01: 0 · 11-02: 10 · 11-03: 3 · 11-04: 1 · 11-05: 0 · 11-06: 0"

    grew = field_value(post, "Grew most")
    assert_operator grew.index("alpha failed"), :<, grew.index("newer failed")
    assert_includes grew, "alpha failed for <email> 2 → 10"
    assert_includes field_value(post, "Disappeared"), "gone failed for <email> 5 → 0"
    refute_includes field_value(post, "Disappeared"), "alpha"
    # alpha too: quiet for a week, back in v2.
    assert_equal "2026-11-02 `RuntimeError` alpha failed for <email> in release v2\n" \
      "2026-11-04 `RuntimeError` rho failed for <email> in release v2", field_value(post, "Regressions after deploys")
    assert_equal "Weekly counts per group come from each day's top 20.", field_value(post, "Data")
    assert_within_discord_limits(post)
  end

  test "the weekly report notes the days it has no data for" do
    occur(group("alpha"), at: Time.utc(2026, 11, 5, 12))

    post = digest("weekly", at: Time.utc(2026, 11, 7, 9))

    data = field_value(post, "Data")
    assert_includes data, "No data for 2026-10-24, 2026-10-25"
    refute_includes data, "2026-11-05,", "a day with errors is known"
    refute_includes data, "2026-11-06", "yesterday is always known"
    refute_includes embed(post)[:description], "vs the previous 7 days"
  end

  test "a group only less frequent is not reported as disappeared" do
    alpha = group("alpha")
    occur(alpha, 30, at: Time.utc(2026, 10, 26, 12))
    # 21 other groups this week push alpha out of the day's top 20.
    21.times { |i| occur(group("other#{i}"), 2, at: Time.utc(2026, 11, 3, 12)) }
    occur(alpha, at: Time.utc(2026, 11, 3, 12))

    post = digest("weekly", at: Time.utc(2026, 11, 7, 9))

    assert_nil field_value(post, "Disappeared")
  end

  # ---- history ---------------------------------------------------------------

  test "every report rewrites the history key" do
    occur(group("alpha"), 2, at: Time.utc(2026, 11, 5, 10))
    digest("daily", at: Time.utc(2026, 11, 6, 9))

    history = Rails.cache.read(Tracker::HISTORY_KEY)
    assert_equal Time.utc(2026, 11, 6, 9).to_i, history["at"]
    assert_equal 2, history.dig("days", "2026-11-05", "t")

    digest("weekly", at: Time.utc(2026, 11, 7, 9))
    assert_equal Time.utc(2026, 11, 7, 9).to_i, Rails.cache.read(Tracker::HISTORY_KEY)["at"]
  end

  test "the history survives the daily keys being evicted" do
    alpha = group("alpha")
    occur(alpha, 4, at: Time.utc(2026, 11, 3, 10))
    occur(alpha, 6, at: Time.utc(2026, 11, 5, 10))
    digest("daily", at: Time.utc(2026, 11, 6, 9))

    Rails.cache.delete_matched(/error_signal:d:/)

    post = digest("weekly", at: Time.utc(2026, 11, 6, 10))
    assert_includes embed(post)[:description], "**10** errors in the last 7 days."
    assert_equal 6, Rails.cache.read(Tracker::HISTORY_KEY).dig("days", "2026-11-05", "t"), "yesterday is not overwritten by the empty keys"
  end

  test "the history keeps 14 days and only the groups they mention" do
    20.times do |i|
      date = Date.new(2026, 10, 1) + i
      occur(group("g#{i}"), at: date.to_time(:utc) + 10.hours)
      digest("daily", at: date.to_time(:utc) + 1.day + 9.hours)
    end

    history = Rails.cache.read(Tracker::HISTORY_KEY)
    assert_equal 14, history["days"].size
    assert_equal "2026-10-07", history["days"].keys.min
    assert_equal 14, history["groups"].size
  end

  # ---- clear_dedupe ----------------------------------------------------------

  test "clear_grouping restarts the bursts and touches nothing else" do
    Rails.cache.write("app:other", "kept")
    error = raised

    posts = capturing_posts do
      3.times { report(error) }
      assert_equal 1, Tracker.clear_grouping
      report(error)
    end

    assert_equal [ "[errorsignaltestapp] [NEW] RuntimeError", "[errorsignaltestapp] RuntimeError - 2nd time in 1 s",
      "[errorsignaltestapp] RuntimeError" ], posts.map { |p| title(p) }
    assert_equal "kept", Rails.cache.read("app:other")
    id = ErrorSignal::Fingerprint.for(error).id
    assert_equal({ id => 4 }, Tracker.day_counts(Tracker.day_for(Time.now.to_i), [ id ]), "the report data stays")
  end

  # ---- delivery --------------------------------------------------------------

  test "deliver says why it did not send" do
    assert_equal :invalid, Report.deliver("monthly").first

    ENV["ERROR_SIGNAL_ENVIRONMENTS"] = "production"
    assert_equal [ :disabled, "Rails.env test is not in ERROR_SIGNAL_ENVIRONMENTS (production)" ], Report.deliver("daily")

    ENV.delete("DISCORD_WEBHOOK_URL")
    assert_equal [ :disabled, "DISCORD_WEBHOOK_URL is not set" ], Report.deliver("daily")
  end

  test "deliver never raises" do
    stub_instance_method(Rails.cache, :read, ->(*) { raise "cache down" }) do
      status, detail = assert_nothing_raised { Report.deliver("daily") }

      assert_equal :failed, status
      assert_includes detail, "cache down"
    end
  end

  test "the DigestJob posts the report and does not raise on a bad period" do
    occur(group("alpha"), at: Time.utc(2026, 11, 5, 10))

    posts = capturing_posts do
      travel_to(Time.utc(2026, 11, 6, 9)) do
        ErrorSignal::DigestJob.perform_now
        ErrorSignal::DigestJob.perform_now("weekly")
        assert_nothing_raised { ErrorSignal::DigestJob.perform_now("monthly") }
      end
    end

    assert_equal [ "Daily", "Weekly" ], posts.map { |p| title(p)[/Daily|Weekly/] }
    assert_operator ErrorSignal::DigestJob, :<, ActiveJob::Base
  end

  test "DigestJob exists only where Active Job is loaded, and the gem does not load it at boot" do
    lib = File.expand_path("../lib", __dir__)
    without = <<~RUBY
      require "rails"
      require "error_signal"
      begin
        ErrorSignal::DigestJob
      rescue NameError
        print "NameError"
      end
    RUBY
    with = <<~RUBY
      require "rails"
      require "active_job/railtie"
      require "error_signal"
      print $LOADED_FEATURES.grep(%r{active_job/base\.rb}).size, " ", ErrorSignal::DigestJob.superclass
    RUBY

    assert_equal "NameError", Open3.capture2(RbConfig.ruby, "-I", lib, "-e", without).first
    assert_equal "0 ActiveJob::Base", Open3.capture2(RbConfig.ruby, "-I", lib, "-e", with).first
  end

  private

  def stub_const(mod, name, value)
    original = mod.const_get(name)
    mod.send(:remove_const, name)
    mod.const_set(name, value)
    yield
  ensure
    mod.send(:remove_const, name)
    mod.const_set(name, original)
  end
end
