# frozen_string_literal: true

require "test_helper"

# Grouping (fingerprint), the power-of-two repetition, new and regressed
# groups, the mention and the spike message.
class GroupingTest < ErrorSignalTestCase
  Fingerprint = ErrorSignal::Fingerprint

  setup do
    ENV["DISCORD_WEBHOOK_URL"] = WEBHOOK
  end

  def error_at(line, klass: RuntimeError, message: "boom")
    error = klass.new(message)
    error.set_backtrace([ line, "/usr/local/bundle/gems/rack-3.2.1/lib/rack.rb:1:in 'call'" ])
    error
  end

  def app_line(text)
    "#{Rails.root}/#{text}"
  end

  # ---- fingerprint -----------------------------------------------------------

  test "numbers, hex ids, UUIDs, e-mails, quoted data and long hashes become placeholders" do
    {
      "Record 123 not found" => "Record <n> not found",
      "Couldn't find User with 'id'=42" => "Couldn't find User with 'id'=<n>",
      "undefined method 'name' for #<User:0x000055d5c5f0a1b8>" => "undefined method 'name' for #<User:<hex>>",
      "order 9d1f6c2e-3b4a-4f5e-8a7b-1c2d3e4f5a6b failed" => "order <uuid> failed",
      "user joao@example.com not found" => "user <email> not found",
      "No such customer: 'cus_9xY2Lm'" => "No such customer: <q>",
      "name \"Jane Doe\" taken" => "name <q> taken",
      "digest 9f86d081884c7d65 mismatch" => "digest <hash> mismatch",
      "token aB3dE5gH7jK9mN1pQ3rS5t rejected" => "token <hash> rejected",
      "price 1,234.56 too high" => "price <n> too high"
    }.each do |message, normalized|
      assert_equal normalized, Fingerprint.normalize(message), message
    end
  end

  test "short quoted identifiers are kept: they tell two bugs apart" do
    assert_equal "undefined method 'email' for nil", Fingerprint.normalize("undefined method 'email' for nil")
    assert_equal "key not found: \"user_id\"", Fingerprint.normalize("key not found: \"user_id\"")
    assert_equal "undefined method `name' for nil", Fingerprint.normalize("undefined method `name' for nil")
  end

  test "the same error with different numbers is one group" do
    a = error_at(app_line("app/models/user.rb:10:in 'User#find_it'"), message: "Record 123 not found")
    b = error_at(app_line("app/models/user.rb:10:in 'User#find_it'"), message: "Record 456 not found")

    assert_equal Fingerprint.for(a).id, Fingerprint.for(b).id
  end

  test "different class, location or message make different groups" do
    base = error_at(app_line("app/models/user.rb:10:in 'User#a'"))
    ids = [
      base,
      error_at(app_line("app/models/user.rb:10:in 'User#a'"), klass: ArgumentError),
      error_at(app_line("app/models/user.rb:10:in 'User#b'")),
      error_at(app_line("app/models/order.rb:10:in 'Order#a'")),
      error_at(app_line("app/models/user.rb:10:in 'User#a'"), message: "other")
    ].map { |e| Fingerprint.for(e).id }

    assert_equal ids.size, ids.uniq.size
  end

  test "the location ignores the line number, the Ruby label style and gem versions" do
    a = Fingerprint.location_key("app/models/user.rb:10:in 'User#display_name'")
    b = Fingerprint.location_key("app/models/user.rb:42:in `display_name'")
    c = Fingerprint.location_key("app/models/user.rb:42:in 'block (2 levels) in User#display_name'")

    assert_equal a, b
    assert_equal a, c
    assert_equal Fingerprint.location_key("/gems/rack-3.2.1/lib/rack.rb:1:in 'call'"),
      Fingerprint.location_key("/gems/rack-3.2.4/lib/rack.rb:9:in 'call'")
  end

  test "the first APP line is the location, past the gem frames" do
    error = RuntimeError.new("x")
    error.set_backtrace([ "/usr/local/bundle/gems/rack-3.2.1/lib/rack.rb:1:in 'call'", app_line("app/jobs/a.rb:3:in 'perform'") ])

    assert_equal "app/jobs/a.rb:3:in 'perform'", Fingerprint.for(error).location
  end

  test "the alert shows the original message, sanitized, not the normalized one" do
    posts = capturing_posts { report(raised(RuntimeError, "Record 123 not found for joao@example.com")) }

    assert_equal "```\nRecord 123 not found for j\u2022\u2022\u2022@example.com\n```", embed(posts.first)[:description]
  end

  # ---- power of two ----------------------------------------------------------

  test "posts the 1st, 2nd, 4th, 8th and 16th occurrences of a burst" do
    error = raised
    posts = capturing_posts { 20.times { report(error) } }

    counts = posts.map { |p| title(p)[/(\d+)(st|nd|rd|th) time/, 1]&.to_i || 1 }
    assert_equal [ 1, 2, 4, 8, 16 ], counts
  end

  test "the title carries the count and the time since the burst started" do
    error = raised

    posts = capturing_posts do
      report(error)
      travel(3.minutes) { report(error) }
      travel(12.minutes) { 2.times { report(error) } }
    end

    assert_equal [ "[errorsignaltestapp] [NEW] RuntimeError", "[errorsignaltestapp] RuntimeError - 2nd time in 3 min",
      "[errorsignaltestapp] RuntimeError - 4th time in 12 min" ], posts.map { |p| title(p) }
  end

  test "different numbers in the message count in the same burst" do
    posts = capturing_posts do
      [ 1, 2, 3, 4 ].each { |n| report(raised(RuntimeError, "Record #{n} not found")) }
    end

    assert_equal 3, posts.size
    assert_includes title(posts.last), "4th time"
  end

  test "a group quiet for the whole window starts a new burst" do
    error = raised

    posts = capturing_posts do
      3.times { report(error) }
      travel(61.minutes) { report(error) }
    end

    assert_equal 3, posts.size
    assert_equal "[errorsignaltestapp] RuntimeError", title(posts.last), "1st of a new burst, and not new: the group was seen"
  end

  test "a burst that keeps going is not reset, however long it lasts" do
    error = raised

    posts = capturing_posts do
      8.times { |i| travel((i * 50).minutes) { report(error) } }
    end

    assert_equal 4, posts.size
    assert_equal "[errorsignaltestapp] RuntimeError - 8th time in 5 h 50 min", title(posts.last)
  end

  test "ERROR_SIGNAL_GROUPING_WINDOW changes the quiet period" do
    ENV["ERROR_SIGNAL_GROUPING_WINDOW"] = "10m"
    error = raised

    posts = capturing_posts do
      2.times { report(error) }
      travel(11.minutes) { report(error) }
    end

    assert_equal 3, posts.size
    assert_equal 600, ErrorSignal::Config.grouping_window
  end

  test "ERROR_SIGNAL_GROUPING_WINDOW accepts seconds and units, and falls back on nonsense" do
    { "90" => 90, "45s" => 45, "30m" => 1800, "2h" => 7200, "1d" => 86_400, "0" => 3600, "soon" => 3600 }.each do |value, seconds|
      ENV["ERROR_SIGNAL_GROUPING_WINDOW"] = value
      assert_equal seconds, ErrorSignal::Config.grouping_window, value
    end
  end

  test "posts every occurrence, without count or markers, when the cache raises" do
    error = raised

    stub_instance_method(Rails.cache, :increment, ->(*) { raise "cache unavailable" }) do
      posts = capturing_posts { 3.times { report(error) } }

      assert_equal 3, posts.size, "a cache outage should not prevent the alert"
      posts.each { |p| assert_equal "[errorsignaltestapp] RuntimeError", title(p) }
    end
  end

  test "posts every occurrence when the cache store swallows its own failure" do
    # The Redis and Memcached stores return nil while the server is down
    # instead of raising.
    stub_instance_method(Rails.cache, :increment, ->(*) { nil }) do
      stub_instance_method(Rails.cache, :read, ->(*) { nil }) do
        posts = capturing_posts { 3.times { report(raised) } }

        assert_equal 3, posts.size
        refute(posts.any? { |p| title(p).include?("NEW") }, "an unreadable cache says nothing about new groups")
      end
    end
  end

  test "with a null store every occurrence is posted" do
    Rails.cache = ActiveSupport::Cache::NullStore.new

    posts = capturing_posts { 3.times { report(raised) } }

    assert_equal 3, posts.size
  end

  # ---- new and regressed -----------------------------------------------------

  test "a group never seen is NEW" do
    posts = capturing_posts { report(raised) }

    assert_equal "[errorsignaltestapp] [NEW] RuntimeError", title(posts.first)
  end

  test "a group not seen for 30 days is NEW again" do
    error = raised

    posts = capturing_posts do
      report(error)
      travel(31.days) { report(error) }
    end

    assert_includes title(posts.last), "[NEW]"
  end

  test "a group back after a quiet day in a new release is REGRESSED" do
    ENV["ERROR_SIGNAL_RELEASE"] = "v1"
    error = raised

    posts = capturing_posts do
      report(error)
      travel(2.days) do
        ENV["ERROR_SIGNAL_RELEASE"] = "v2"
        report(error)
      end
    end

    assert_equal "[errorsignaltestapp] [REGRESSED] RuntimeError", title(posts.last)
    assert_equal "2 d ago, in release v1", field_value(posts.last, "Previously seen")
  end

  test "not REGRESSED without a quiet day, without a release change, or without a release" do
    error = raised

    posts = capturing_posts do
      ENV["ERROR_SIGNAL_RELEASE"] = "v1"
      report(error)
      travel(2.hours) do # new release, but quiet for less than a day
        ENV["ERROR_SIGNAL_RELEASE"] = "v2"
        report(error)
      end
      travel(4.days) { report(error) } # quiet for days, same release (v2)
      ENV.delete("ERROR_SIGNAL_RELEASE")
      travel(8.days) { report(error) } # quiet for days, no release
    end

    assert_equal 4, posts.size
    posts.drop(1).each { |p| assert_equal "[errorsignaltestapp] RuntimeError", title(p) }
  end

  test "only the 1st occurrence of a new burst carries the marker" do
    error = raised

    posts = capturing_posts { 2.times { report(error) } }

    assert_includes title(posts.first), "[NEW]"
    refute_includes title(posts.last), "[NEW]"
  end

  test "DISCORD_MENTION pings on new, regressed and spike messages only" do
    ENV["DISCORD_MENTION"] = "@here"
    ENV["ERROR_SIGNAL_RELEASE"] = "v1"
    error = raised

    posts = capturing_posts do
      2.times { report(error) }
      travel(2.days) do
        ENV["ERROR_SIGNAL_RELEASE"] = "v2"
        report(error)
      end
    end

    assert_equal [ "@here", nil, "@here" ], posts.map { |p| p[:content] }
    assert_equal({ parse: [ "everyone" ] }, posts.first[:allowed_mentions])
    assert_equal({ parse: [] }, posts[1][:allowed_mentions], "a message without the mention pings nobody")
  end

  test "DISCORD_MENTION with a role or a user allows exactly those" do
    ENV["DISCORD_MENTION"] = "<@&123456> <@789> not-a-mention"

    posts = capturing_posts { report(raised) }

    assert_equal "<@&123456> <@789>", posts.first[:content]
    assert_equal({ parse: [], roles: [ "123456" ], users: [ "789" ] }, posts.first[:allowed_mentions])
  end

  test "without DISCORD_MENTION a new group pings nobody" do
    posts = capturing_posts { report(raised) }

    assert_nil posts.first[:content]
    assert_equal({ parse: [] }, posts.first[:allowed_mentions])
  end

  # ---- spike -----------------------------------------------------------------

  def spikes(posts)
    posts.select { |p| title(p).include?("[SPIKE]") }
  end

  test "more than ERROR_SIGNAL_SPIKE occurrences in 5 minutes post one spike message" do
    ENV["ERROR_SIGNAL_SPIKE"] = "5"
    ENV["DISCORD_MENTION"] = "@here"
    error = raised

    posts = capturing_posts do
      travel_to(Time.utc(2026, 11, 7, 10, 0, 1)) { 20.times { report(error) } }
    end

    assert_equal 1, spikes(posts).size
    spike = spikes(posts).first
    assert_equal "[errorsignaltestapp] [SPIKE] RuntimeError", title(spike)
    assert_includes embed(spike)[:description], "More than 5 occurrences in 5 min."
    assert_equal "@here", spike[:content]
    assert_equal ErrorSignal::Alert::COLOR_SPIKE, embed(spike)[:color]
  end

  test "the spike message goes out once per 5-minute window" do
    ENV["ERROR_SIGNAL_SPIKE"] = "5"
    error = raised

    posts = capturing_posts do
      travel_to(Time.utc(2026, 11, 7, 10, 0, 1)) { 10.times { report(error) } }
      travel_to(Time.utc(2026, 11, 7, 10, 1, 0)) { 10.times { report(error) } }
      travel_to(Time.utc(2026, 11, 7, 10, 5, 1)) { 10.times { report(error) } }
    end

    assert_equal 2, spikes(posts).size
  end

  test "no spike at or below the threshold, and none with ERROR_SIGNAL_SPIKE=0" do
    ENV["ERROR_SIGNAL_SPIKE"] = "5"
    error = raised
    posts = capturing_posts { travel_to(Time.utc(2026, 11, 7, 10, 0, 1)) { 5.times { report(error) } } }
    assert_empty spikes(posts)

    ENV["ERROR_SIGNAL_SPIKE"] = "0"
    posts = capturing_posts { travel_to(Time.utc(2026, 11, 7, 11, 0, 1)) { 100.times { report(error) } } }
    assert_empty spikes(posts)
  end

  # ---- locale ----------------------------------------------------------------

  test "markers, counts and durations in Portuguese" do
    ENV["ERROR_SIGNAL_LOCALE"] = "pt-BR"
    ENV["ERROR_SIGNAL_SPIKE"] = "3"
    ENV["ERROR_SIGNAL_RELEASE"] = "v1"
    error = raised

    posts = capturing_posts do
      travel_to(Time.utc(2026, 11, 7, 10, 0, 1)) { report(error) }
      travel_to(Time.utc(2026, 11, 7, 10, 2, 1)) { 3.times { report(error) } }
      travel_to(Time.utc(2026, 11, 9, 13, 0, 0)) do
        ENV["ERROR_SIGNAL_RELEASE"] = "v2"
        report(error)
      end
    end

    titles = posts.map { |p| title(p) }
    assert_equal "[errorsignaltestapp] [NOVO] RuntimeError", titles[0]
    assert_equal "[errorsignaltestapp] RuntimeError - 2ª vez em 2 min", titles[1]
    assert_equal "[errorsignaltestapp] RuntimeError - 4ª vez em 2 min", titles[2]
    assert_equal "[errorsignaltestapp] [PICO] RuntimeError", titles[3]
    assert_includes embed(posts[3])[:description], "Mais de 3 ocorrências em 5 min."
    assert_equal "[errorsignaltestapp] [VOLTOU] RuntimeError", titles[4]
    assert_equal "há 2 d, na release v1", field_value(posts[4], "Visto antes")
  end

  test "ordinals and durations" do
    text = ErrorSignal::Text
    assert_equal %w[1st 2nd 3rd 4th 11th 12th 13th 21st 22nd 32nd 64th 101st 112th 1024th],
      [ 1, 2, 3, 4, 11, 12, 13, 21, 22, 32, 64, 101, 112, 1024 ].map { |n| text.ordinal(n, "en") }
    assert_equal "8ª", text.ordinal(8, "pt-BR")
    assert_equal [ "1 s", "45 s", "12 min", "3 h", "3 h 5 min", "2 d" ],
      [ 0, 45, 720, 10_800, 11_100, 200_000 ].map { |s| text.duration(s) }
  end
end
