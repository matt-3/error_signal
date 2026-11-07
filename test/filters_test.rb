# frozen_string_literal: true

require "test_helper"

# What is never posted: other environments, ignored classes and crawlers.
class FiltersTest < ErrorSignalTestCase
  setup do
    ENV["DISCORD_WEBHOOK_URL"] = WEBHOOK
  end

  # Errors that live in a namespace of their own, to check ancestors and
  # names of classes the app does not load.
  module Noise; end
  class NoisyError < StandardError
    include Noise
  end
  class LoudError < NoisyError; end

  # ---- environments ----------------------------------------------------------

  test "by default it posts only in production" do
    ENV.delete("ERROR_SIGNAL_ENVIRONMENTS")

    posts = capturing_posts { report(raised) }

    assert_empty posts
    assert_equal %w[production], ErrorSignal::Config.environments
    refute ErrorSignal::Config.enabled?
  end

  test "ERROR_SIGNAL_ENVIRONMENTS takes a list, in any case" do
    ENV["ERROR_SIGNAL_ENVIRONMENTS"] = "Staging, TEST"

    posts = capturing_posts { report(raised) }

    assert_equal 1, posts.size
    assert_equal %w[staging test], ErrorSignal::Config.environments
  end

  test "outside the listed environments nothing is counted" do
    ENV["ERROR_SIGNAL_ENVIRONMENTS"] = "production"
    error = raised

    report(error)

    assert_nil Rails.cache.read(ErrorSignal::Tracker.state_key(ErrorSignal::Fingerprint.for(error).id))
  end

  # ---- ignored exceptions ----------------------------------------------------

  test "the default list ignores the classic noise wherever it comes from" do
    posts = capturing_posts do
      ErrorSignal::Config::DEFAULT_IGNORED_EXCEPTIONS.each do |name|
        report(raised(name.constantize, "noise"), source: "application.active_support")
      end
    end

    assert_empty posts
  end

  test "the defaults do not repeat the 4xx rule's classes, which are real bugs in a job" do
    defaults = ErrorSignal::Config::DEFAULT_IGNORED_EXCEPTIONS

    refute_includes defaults, "ActiveRecord::RecordNotFound"
    refute_includes defaults, "ActionController::RoutingError"
    posts = capturing_posts { report(raised(ActionController::RoutingError, "in a job"), source: "application.active_support") }
    assert_equal 1, posts.size
  end

  test "ERROR_SIGNAL_IGNORE_EXCEPTIONS matches the class and its ancestors, modules included" do
    ENV["ERROR_SIGNAL_IGNORE_EXCEPTIONS"] = "FiltersTest::Noise, KeyError"

    posts = capturing_posts do
      report(raised(LoudError, "subclass of a class that includes the module"))
      report(raised(KeyError, "listed directly"))
      report(raised(ArgumentError, "not listed"))
    end

    assert_equal [ "ArgumentError" ], posts.map { |p| title(p)[/\w+Error/] }
  end

  test "a superclass in the list covers its subclasses" do
    ENV["ERROR_SIGNAL_IGNORE_EXCEPTIONS"] = "FiltersTest::NoisyError"

    posts = capturing_posts { report(raised(LoudError)) }

    assert_empty posts
  end

  test "an unknown class name in the list is harmless" do
    ENV["ERROR_SIGNAL_IGNORE_EXCEPTIONS"] = "Not::Loaded::Error,,"

    posts = capturing_posts { report(raised) }

    assert_equal 1, posts.size
  end

  test "ERROR_SIGNAL_IGNORE_EXCEPTIONS_DEFAULTS=false turns the defaults off and keeps the custom list" do
    ENV["ERROR_SIGNAL_IGNORE_EXCEPTIONS_DEFAULTS"] = "false"
    ENV["ERROR_SIGNAL_IGNORE_EXCEPTIONS"] = "KeyError"

    posts = capturing_posts do
      report(raised(ActionController::BadRequest, "now posted"), source: "application.active_support")
      report(raised(KeyError, "still ignored"))
    end

    assert_equal [ "ActionController::BadRequest" ], posts.map { |p| title(p)[/[\w:]+(?=\z| -)/] }
    assert_equal [ "KeyError" ], ErrorSignal::Config.ignored_exceptions
  end

  # ---- crawlers --------------------------------------------------------------

  CRAWLERS = [
    "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)",
    "Mozilla/5.0 (compatible; bingbot/2.0; +http://www.bing.com/bingbot.htm)",
    "Mozilla/5.0 (compatible; YandexBot/3.0; +http://yandex.com/bots)",
    "Mozilla/5.0 (compatible; Baiduspider/2.0; +http://www.baidu.com/search/spider.html)",
    "DuckDuckBot/1.1; (+http://duckduckgo.com/duckduckbot.html)",
    "Mozilla/5.0 (Macintosh) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15 (Applebot/0.1)",
    "Mozilla/5.0 (compatible; AhrefsBot/7.0; +http://ahrefs.com/robot/)",
    "Mozilla/5.0 (compatible; SemrushBot/7~bl; +http://www.semrush.com/bot.html)",
    "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; GPTBot/1.1; +https://openai.com/gptbot)",
    "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; ClaudeBot/1.0; +claudebot@anthropic.com)",
    "CCBot/2.0 (https://commoncrawl.org/faq/)",
    "Mozilla/5.0 (Linux; Android 5.0) AppleWebKit/537.36 (KHTML, like Gecko) Mobile Safari/537.36 (compatible; Bytespider; spider-feedback@bytedance.com)",
    "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; PerplexityBot/1.0; +https://perplexity.ai/perplexitybot)",
    "Slackbot-LinkExpanding 1.0 (+https://api.slack.com/robots)",
    "Twitterbot/1.0",
    "Sogou web spider/4.0",
    "SomeCrawler/3.1",
    "my bot"
  ].freeze

  BROWSERS = [
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36",
    "Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Mobile/15E148 Safari/604.1",
    "Mozilla/5.0 (Linux; Android 10; CUBOT X20 PRO) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36",
    "Mozilla/5.0 (Linux; Android 11; CUBOT_X30) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36",
    "curl/8.7.1"
  ].freeze

  test "recognizes crawlers by name and by the generic bot, crawl and spider words" do
    CRAWLERS.each { |agent| assert_match ErrorSignal::Filters::CRAWLER, agent }
  end

  test "does not take browsers and phones for crawlers" do
    BROWSERS.each { |agent| refute_match ErrorSignal::Filters::CRAWLER, agent }
  end
end
