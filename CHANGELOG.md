# Changelog

All notable changes to this project are documented in this file. Versions follow
[Semantic Versioning](https://semver.org/), and each one is a `vX.Y.Z` git tag.

## v1.0.0 - 2026-11-07

First release: Sentry-like alerts and daily/weekly error reports for Rails, posted to
Discord. No service, no database, no runtime dependency besides `activesupport` and
`railties`; the Gemfile line and `DISCORD_WEBHOOK_URL` are the whole setup.

### Capture

- **Rails.error.** A Railtie subscribes `ErrorSignal::Subscriber` to `Rails.error`, so
  the errors Rails reports from requests, jobs and `rails runner` reach it, next to any
  other subscriber (Sentry, solid_errors). `Rails.error.disable(ErrorSignal::Subscriber)`
  silences it for a block.
- **Rake tasks and the corners of `rails runner`.** A module prepended to
  `Rake::Application#display_error_message` reports the exception that ends a rake run,
  with the task where it was raised. An `at_exit` check, registered only for
  `rails runner`, reports what the runner's executor misses (`--skip-executor`,
  `LoadError`, `NotImplementedError`). An exception already seen by `Rails.error` or by
  Error Signal is never posted twice.
- **No lost alert at exit.** Alerts are posted from a thread; an `at_exit` hook waits up
  to 5 seconds for the posts in flight.
- **Manual use.** `ErrorSignal.notify(exception, context: {}, severity: :error)` posts an
  exception to Discord only, and `ErrorSignal.flush` waits for the posts.
- **Messages with no exception.** `ErrorSignal.message(text, level:, fields:, key:,
  mention:)` posts a sanitized text with fields, colored by level, grouped by text (or
  `key:`) in powers of two within the grouping window, and left out of the reports.

### Alerts

- **Grouping by fingerprint**: exception class, first app backtrace line without the line
  number, and the message normalized (numbers, hex ids, UUIDs, e-mails, long hashes and
  quoted data become placeholders; short quoted identifiers stay).
- **Power-of-two repetition**: a group posts on its 1st, 2nd, 4th, 8th... occurrence of a
  burst, with the count and the elapsed time in the title (`8th time in 12 min`). The
  burst ends after `ERROR_SIGNAL_GROUPING_WINDOW` (1 hour) of quiet. Counted with
  `Rails.cache.increment`, atomic across processes; a cache failure posts every
  occurrence.
- **New and regressed**: groups are remembered for 30 days. A group not seen in that time
  is `[NEW]`; one that comes back after at least a quiet day in another release
  (`ERROR_SIGNAL_RELEASE`, `SENTRY_RELEASE` or `GIT_REV`) is `[REGRESSED]`, with when and
  in which release it was last seen.
- **Spikes**: more than `ERROR_SIGNAL_SPIKE` (50) occurrences of a group in 5 minutes post
  a separate `[SPIKE]` message, once per window.
- **Mention**: `DISCORD_MENTION` (`@here`, a role or a user) goes on new, regressed and
  spike messages only; every message restricts `allowed_mentions`.
- **Only what matters**: severity `error` by default (`ERROR_SIGNAL_MIN_LEVEL`), only in
  `ERROR_SIGNAL_ENVIRONMENTS` (default `production`), never request errors Rails answers
  with a 4xx, never cache store failures, never the classes of
  `ERROR_SIGNAL_IGNORE_EXCEPTIONS` (matched against ancestors) or the default noise list
  (`ERROR_SIGNAL_IGNORE_EXCEPTIONS_DEFAULTS=false` turns it off), and never errors of
  crawler requests (`ERROR_SIGNAL_IGNORE_CRAWLERS`). `ERROR_SIGNAL_IGNORE_SOURCES` leaves
  sources out by prefix, `ERROR_SIGNAL_REPORT_HANDLED=false` posts only what the app did
  not rescue, and `ErrorSignal.ignore_if { |error, event| ... }` takes any rule in Ruby (a
  rule that raises is skipped, and the error posts). A tiny Rack middleware keeps the
  request's env reachable, for the User-Agent and the request id of errors raised outside
  a controller.
- **Useful context, nothing private**: the source, `Controller#action`, the route
  pattern (`GET /orders/:id`, Rails 7.1+ `route_uri_pattern`, never the URL) and the request
  id, the job class and id or the rake task, the location and up to 5 app backtrace
  lines, the release. No params, headers or URL. Within Discord's limits: what does not
  fit the 6000 characters of a message (a long exception message, more app backtrace
  lines than the alert shows, the fields of a long `ErrorSignal.message`, the groups a
  report does not list) goes whole and sanitized in an attached text file; if Discord
  refuses the file, the message is posted without it.
- **One author for every message**: posted as "Error Signal", with the app name
  (`ERROR_SIGNAL_APP_NAME`, default the app module name) in the title and the footer, so
  several apps can share a channel. The requests carry an `error_signal/<version>`
  User-Agent.

### Reports

- **Daily and weekly reports** through `ErrorSignal::DigestJob` (defined when the app
  loads Active Job) and `bin/rails "error_signal:digest[daily|weekly]"`: totals and
  comparison, top groups with first and last seen, new and regressed groups (daily);
  trend, per-day counts, groups that grew most or disappeared, and regressions after
  deploys (weekly). Days follow `config.time_zone`.
- **Data in Rails.cache**, under the `error_signal:` prefix: daily counters per group (15
  days), group state (30 days), and one history key with 14 days of summaries rewritten by
  every report, so it survives Solid Cache's `max_age` and size eviction. The report says
  when its data is incomplete.

### Sanitizer

- **Masked, not erased** (`ERROR_SIGNAL_MASK=partial`, the default): personal data keeps
  the part that tells records apart (CPF `•••.456.789-••`, CNPJ `••.345.678/0001-••`,
  cards, phones and national ids their last four, IBAN and VAT the country and the last
  four, e-mails `j•••@gmail.com`); secrets are always `[FILTERED]` whole.
  `ERROR_SIGNAL_MASK=full` filters personal data whole too.
- **Global layer, always on**: e-mails, phone numbers, payment cards checked with Luhn,
  IBANs checked with mod 97, JWTs, `Bearer`/`Basic` credentials, AWS, Stripe, GitHub,
  Google and Slack keys, Discord webhook URLs, long secrets, cookie headers, sensitive
  URL query parameters and `key=value` pairs. Dates, versions, ids, prices and Ruby
  constants stay readable.
- **Country packs, opt-in** through `ERROR_SIGNAL_PII_RULES`: `br` (CPF, CNPJ including
  the alphanumeric format, bare mobile numbers), `us` (SSN, EIN), `uk` (National
  Insurance number), `in` (Aadhaar with Verhoeff, PAN) and `eu` (VAT numbers with country
  prefix).
- **Your own**: `ErrorSignal.sanitizer = ->(text) { ... }` replaces the built-in one.
  Fail-closed: if the sanitizer raises, the localized `[sanitization failed]` marker goes
  out instead of the text.

### Tooling

- Rake tasks `error_signal:check` (every setting, the cache store and what it means for
  the data, the report history), `error_signal:test`, `error_signal:test_repeat`,
  `error_signal:clear_dedupe` (resets only Error Signal's grouping and spike keys) and
  `error_signal:digest`.
- Messages in English (default) or Portuguese (Brazil) through `ERROR_SIGNAL_LOCALE`.
- Never raises, never blocks a request: the POST runs in a thread with short timeouts,
  and each error costs a few cache operations.
- Tested on Ruby 3.4 and 4.0 with Rails 7.1, 7.2, 8.0 and 8.1 (`gemfiles/`).
