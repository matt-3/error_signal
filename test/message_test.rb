# frozen_string_literal: true

require "test_helper"

# ErrorSignal.message: a message with no exception.
class MessageTest < ErrorSignalTestCase
  setup do
    ENV["DISCORD_WEBHOOK_URL"] = WEBHOOK
    ENV["ERROR_SIGNAL_APP_NAME"] = "shop"
  end

  test "posts the text with the app in the title, colored by level" do
    posts = capturing_posts do
      assert ErrorSignal.message("Stock of product 42 ran out", level: :warning)
    end

    assert_equal 1, posts.size
    assert_equal "[shop] Stock of product 42 ran out", title(posts.first)
    assert_equal ErrorSignal::Alert::COLOR_WARNING, embed(posts.first)[:color]
    refute embed(posts.first).key?(:description), "a one-line message lives in the title"
    assert_within_discord_limits posts.first
  end

  test "info is the default level, an unknown level is info too" do
    posts = capturing_posts do
      ErrorSignal.message("one")
      ErrorSignal.message("two", level: :loud)
    end

    assert_equal [ ErrorSignal::Alert::COLOR_INFO ] * 2, posts.map { |post| embed(post)[:color] }
  end

  test "a multi-line text keeps its first line in the title and the other lines in the description" do
    posts = capturing_posts { ErrorSignal.message("Import finished with errors\n3 rows skipped\nsee the log") }

    assert_equal "[shop] Import finished with errors", title(posts.first)
    assert_equal "3 rows skipped\nsee the log", embed(posts.first)[:description]
  end

  test "a first line too long for the title goes whole in the description" do
    text = "word " * 60
    posts = capturing_posts { ErrorSignal.message(text) }

    assert title(posts.first).end_with?("...")
    assert_equal text.strip, embed(posts.first)[:description]
  end

  test "sanitizes the text, the field names and the values" do
    ENV["ERROR_SIGNAL_PII_RULES"] = "br"
    posts = capturing_posts do
      ErrorSignal.message("Refund for joao@example.com failed", fields: { "CPF" => "123.456.789-09", "token=abc" => "x" })
    end

    body = json(posts.first)
    refute_includes body, "joao@example.com"
    refute_includes body, "123.456.789-09"
    assert_equal "•••.456.789-••", field_value(posts.first, "CPF")
    assert_includes field_names(posts.first), "token=[FILTERED]"
  end

  test "fields go inline, in order, and an empty value becomes a dash" do
    posts = capturing_posts { ErrorSignal.message("x", fields: { order: 7, note: "" }) }

    assert_equal [ { name: "order", value: "7", inline: true }, { name: "note", value: "-", inline: true } ],
      embed(posts.first)[:fields]
  end

  test "many long fields stay within Discord's limits" do
    fields = (1..30).to_h { |i| [ "field #{i}", "v" * 2000 ] }
    posts = capturing_posts { ErrorSignal.message("x" * 5000, fields: fields) }

    assert_within_discord_limits posts.first
    assert_operator embed(posts.first)[:fields].size, :<=, ErrorSignal::Alert::MESSAGE_FIELDS
  end

  test "mentions only with mention: true" do
    ENV["DISCORD_MENTION"] = "@here"

    posts = capturing_posts do
      ErrorSignal.message("quiet")
      ErrorSignal.message("loud", mention: true)
    end

    assert_nil posts.first[:content]
    assert_equal "@here", posts.last[:content]
    assert_equal({ parse: [] }, posts.first[:allowed_mentions])
  end

  test "the same text is grouped: 1st, 2nd and 4th post, with the count in the title" do
    posts = capturing_posts { 5.times { ErrorSignal.message("Gateway slow") } }

    assert_equal 3, posts.size
    assert_match(/\A\[shop\] Gateway slow - 4th time in /, title(posts.last))
  end

  test "key: groups different texts as one" do
    posts = capturing_posts do
      %w[41 42 43].each { |id| ErrorSignal.message("Stock of product #{id} ran out", key: "stock") }
    end

    assert_equal 2, posts.size
  end

  test "different texts without a key post each" do
    posts = capturing_posts do
      %w[41 42 43].each { |id| ErrorSignal.message("Stock of product #{id} ran out") }
    end

    assert_equal 3, posts.size
  end

  test "the grouping starts again after the window" do
    ENV["ERROR_SIGNAL_GROUPING_WINDOW"] = "10m"
    posts = capturing_posts do
      3.times { ErrorSignal.message("again") }
      travel 11.minutes do
        ErrorSignal.message("again")
      end
    end

    assert_equal 3, posts.size
    assert_equal "[shop] again", title(posts.last)
  end

  test "a cache failure posts without grouping" do
    broken = Object.new
    def broken.fetch(*) = raise("cache down")
    original = Rails.cache
    Rails.cache = broken

    posts = capturing_posts { 2.times { ErrorSignal.message("cache test") } }

    assert_equal 2, posts.size
  ensure
    Rails.cache = original
  end

  test "is not counted in the error reports" do
    capturing_posts { ErrorSignal.message("not an error") }

    assert_empty ErrorSignal::Tracker.day_ids(ErrorSignal::Tracker.day_for(Time.now.to_i))
  end

  test "does nothing outside the enabled environments or without a text" do
    posts = capturing_posts do
      refute ErrorSignal.message("   ")
      ENV["ERROR_SIGNAL_ENVIRONMENTS"] = "production"
      refute ErrorSignal.message("not here")
    end

    assert_empty posts
  end

  test "never raises" do
    posts = capturing_posts do
      refute ErrorSignal.message("x", fields: 42)
    end

    assert_empty posts
  end
end
