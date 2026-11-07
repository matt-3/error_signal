# Contributing

English | [Português](CONTRIBUTING.pt-BR.md)

Thanks for helping. Bug reports, fixes, improvements and translations are all welcome.

## Reporting a bug

Open an issue with:

- the Ruby and Rails versions, and the cache store your app uses;
- what you did, what you expected and what happened;
- the `[ErrorSignal]` lines from your log, if there are any;
- the output of `bin/rails error_signal:check`.

Leave real webhook URLs, tokens and personal data out of the issue. If the bug is a
leak (personal data or a secret reaching Discord), describe the shape of the data (for
example "a phone number written as `11 9 1234 5678`") instead of the real value.

## Before a bigger change

Open an issue first for anything beyond a small fix: a new dependency, a new setting, a
change in what gets posted or in the message format. The gem is meant to stay small and
safe to drop into any Rails app, so it is worth agreeing on the approach before you
write the code.

## Making a change

1. Fork the repository and create a branch.
2. Install the dependencies and run the checks:

   ```bash
   bundle install
   bundle exec rake test
   bundle exec rubocop
   ```

   To run one Rails version of the CI matrix, point Bundler at its gemfile:

   ```bash
   BUNDLE_GEMFILE=gemfiles/rails_7_1.gemfile bundle install
   BUNDLE_GEMFILE=gemfiles/rails_7_1.gemfile bundle exec rake test
   ```

3. Add a test for the change. The tests run against a small Rails app
   (`test/test_helper.rb`) and never touch the network: `capturing_posts` collects the
   payloads instead of posting them, and `test/capture_test.rb` runs real `rails runner`
   and rake processes against a local webhook.
4. Keep the guarantees: Error Signal never raises, never blocks the request, adds no
   runtime dependency, costs a few cache operations per error, and never lets text out
   unsanitized. A change that weakens one of them needs a very good reason in the pull
   request.
5. Update both READMEs (`README.md` and `README.pt-BR.md`) when behavior or
   configuration changes, and add a line to `CHANGELOG.md`. If the text of a message
   changes, update the payloads in `docs/assets/make_images.py` and run it
   (`python3 docs/assets/make_images.py`): the README images show the real messages.
6. Open the pull request describing what changed and why.

CI runs the tests on every pair of Ruby 3.4 and 4.0 with Rails 7.1, 7.2, 8.0 and 8.1, and
RuboCop and `gem build` once.

## Translating the messages

1. Add the locale to `MESSAGES` in `lib/error_signal/messages.rb`, with every key
   and the same `%{placeholders}` (the test `every locale defines every message key, with
   the same placeholders` checks it).
2. Teach `ErrorSignal::Config.locale` to recognize the new `ERROR_SIGNAL_LOCALE` value.
3. Add a test that renders an alert and a report in the new locale, and mention the locale
   in the `ERROR_SIGNAL_LOCALE` row of both READMEs.

## Improving the built-in sanitizer

The global rules live in `lib/error_signal/sanitizer.rb`, and each country pack
in its own file under `lib/error_signal/pii/` (registered in `pii.rb`). For each
new rule, add to `test/sanitizer_test.rb` examples it must redact and examples it must
leave alone, and make sure `does not mangle backtraces, class names, dates, versions, ids,
prices or prose` still passes: a rule that eats dates, ids or class names makes the
message useless. Prefer a check digit (Luhn, mod 97, mod 11) to a bare shape whenever the
document has one, and put national documents in a pack, not in the global layer.

Decide what the rule replaces the match with. Personal data takes a partial mask
(`Sanitizer::Mask.last` for the last four, `Sanitizer::Mask.keep` for the positions that
tell records apart without being a fixed suffix, as the CNPJ branch is), and its expected
shape goes in `test/mask_test.rb`. A secret (a password, a token, a key) takes
`Sanitizer::FILTERED` whole and is never masked in part.

## License

By contributing, you agree that your contributions are released under the
[MIT License](LICENSE).
