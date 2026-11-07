# frozen_string_literal: true

require "test_helper"

# One test per kind of data the built-in sanitizer redacts, and the text it
# must leave alone (a sanitizer that eats dates, versions, ids and prices
# would make the message useless). Runs with ERROR_SIGNAL_MASK=full, so every
# detection shows as [FILTERED]; the partial masks are in mask_test.rb.
class SanitizerTest < ActiveSupport::TestCase
  setup do
    @original = ENV.to_h.slice("ERROR_SIGNAL_PII_RULES", "ERROR_SIGNAL_MASK")
    ENV.delete("ERROR_SIGNAL_PII_RULES")
    ENV["ERROR_SIGNAL_MASK"] = "full"
  end

  teardown do
    %w[ERROR_SIGNAL_PII_RULES ERROR_SIGNAL_MASK].each { |name| ENV.delete(name) }
    @original.each { |name, value| ENV[name] = value }
  end

  def clean(text)
    ErrorSignal::Sanitizer.call(text)
  end

  def assert_redacts(text, secret)
    result = clean(text)
    refute_includes result, secret, "#{text.inspect} leaked #{secret.inspect}: #{result.inspect}"
    assert_includes result, "[FILTERED]"
  end

  def assert_keeps(text)
    assert_equal text, clean(text), "#{text.inspect} should stay as it is"
  end

  # ---- global layer ----------------------------------------------------------

  test "e-mails" do
    assert_redacts "user joao.silva+tag@example.com.br not found", "joao.silva+tag@example.com.br"
  end

  test "international phone numbers with a plus" do
    {
      "call +5511912345678 now" => "5511912345678",
      "call +55 (11) 91234-5678 now" => "91234-5678",
      "call +1 415-555-2671 now" => "555-2671",
      "call +1 (415) 555-2671 now" => "555-2671",
      "call +44 20 7946 0958 now" => "7946 0958",
      "call +33 1 23 45 67 89 now" => "45 67 89",
      "call +49 30 1234567 now" => "1234567"
    }.each { |text, secret| assert_redacts text, secret }
  end

  test "a phone followed by a date loses the phone, keeps the date" do
    assert_equal "call [FILTERED] on 2026-11-07", clean("call +55 11 91234-5678 on 2026-11-07")
    assert_equal "[FILTERED] 2026-11-07 14:03", clean("+44 20 7946 0958 2026-11-07 14:03")
  end

  test "grouped phone formats without a plus" do
    {
      "call (11) 91234-5678 now" => "91234-5678",
      "call (415) 555-2671 now" => "555-2671",
      "call 415-555-2671 now" => "555-2671",
      "call 415.555.2671 now" => "555.2671",
      "call 11 3456-7890 now" => "3456-7890",
      "call 91234-5678 now" => "91234-5678",
      "call 555-2671 now" => "555-2671",
      "call 020 7946 0958 now" => "7946 0958",
      "call 0161 496 0000 now" => "496 0000",
      "call 030 1234567 now" => "1234567",
      "call 01 23 45 67 89 now" => "45 67 89"
    }.each { |text, secret| assert_redacts text, secret }
  end

  test "payment cards valid under Luhn, grouped or not" do
    assert_redacts "card 4111 1111 1111 1111 declined", "1111 1111 1111"
    assert_redacts "card 4111-1111-1111-1111 declined", "1111-1111-1111"
    assert_redacts "card 4111111111111111 declined", "4111111111111111"
    assert_redacts "card 378282246310005 declined", "378282246310005"
    assert_redacts "card 5555555555554444 declined", "5555555555554444"
  end

  test "long numbers that fail Luhn are ids, not cards" do
    assert_keeps "order 4111111111111112 not found"
    assert_keeps "import 1234567890123 failed"
    assert_keeps "at 1730985600000 ms"
  end

  test "IBANs valid under mod 97" do
    assert_redacts "IBAN GB82 WEST 1234 5698 7654 32 rejected", "WEST 1234"
    assert_redacts "IBAN DE89370400440532013000 rejected", "DE89370400440532013000"
    assert_redacts "IBAN FR1420041010050500013M02606 rejected", "FR1420041010050500013M02606"
    refute ErrorSignal::PII::Checksums.iban?("GB82WEST12345698765433")
  end

  test "bearer tokens and basic credentials" do
    assert_redacts "Authorization: Bearer abc.DEF-123_xyz~", "abc.DEF-123_xyz"
    assert_redacts "header bearer eyJhbGciOi.payload.sig", "eyJhbGciOi"
    assert_redacts "Authorization: Basic dXNlcjpwYXNzd29yZA==", "dXNlcjpwYXNzd29yZA"
    assert_redacts "sent Bearer abcdefgh12345678 upstream", "abcdefgh12345678"
  end

  test "JSON Web Tokens" do
    jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
    assert_redacts "token #{jwt} expired", jwt
  end

  # Fake keys, built at run time so the file never holds the literal shape
  # secret scanners look for (GitHub push protection blocks a push with
  # one). AKIAIOSFODNN7EXAMPLE is AWS's own documentation example.
  test "service keys with a known prefix" do
    [
      "AKIAIOSFODNN7EXAMPLE",
      %w[ASIA Y34FZKBOKMUTVV7A].join,
      %w[sk live 51H8abcdefGHIJKLmnop].join("_"),
      %w[rk test abcdefghij1234].join("_"),
      "ghp_#{'a1B2' * 9}",
      "gho_#{'a1B2' * 9}",
      "ghs_#{'a1B2' * 9}",
      %w[github pat 11ABCDEFG0123456789 abcdefghijklmnopqrstuvwxyz].join("_"),
      %w[AIza SyA1234567890abcdefghijklmnopqrstu].join,
      %w[xoxb 123456789012 1234567890123 abcdefghijklmnop].join("-"),
      %w[xoxp 123456789012 1234567890123 abcdefghijklmnop].join("-")
    ].each { |key| assert_redacts "used #{key} here", key }
  end

  test "Discord webhook URLs" do
    %w[
      https://discord.com/api/webhooks/123456789/abcDEF-123_xyz
      https://discordapp.com/api/webhooks/123456789/abcDEF-123_xyz
      https://canary.discord.com/api/webhooks/123456789/abcDEF-123_xyz
    ].each { |url| assert_redacts "posting to #{url} failed", "abcDEF-123_xyz" }
  end

  test "key=value and \"key\": \"value\" credentials outside URLs" do
    assert_redacts "token=abc123 rejected", "abc123"
    assert_redacts "failed with api_key=sk_abc and more", "sk_abc"
    assert_redacts "config {\"password\": \"hunter2\"}", "hunter2"
    assert_redacts "config {\"password\": \"hunter 2 words\"}", "words"
    assert_redacts "client_secret: s3cr3t-value", "s3cr3t-value"
    assert_redacts "X-Api-Key=abc", "abc"
    assert_redacts "access_key=AK1 private_key=PK2", "AK1"
    assert_redacts "access_key=AK1 private_key=PK2", "PK2"
    assert_redacts "session_id=abc123 expired", "abc123"
    assert_redacts "Authorization: Token abc123", "abc123"
  end

  test "cookie headers lose every cookie" do
    result = clean("Cookie: _app_session=abc123; remember_token=xyz789")

    assert_equal "Cookie: [FILTERED]", result
    assert_redacts "Set-Cookie: _app_session=abc123; path=/", "abc123"
  end

  test "URL query values of sensitive parameters, keeping the others" do
    url = "https://example.com/reset?password=hunter2&page=2&token=abc&secret=s&api_key=k&code=123456" \
      "&reset_password_token=xyz&session=sss&authorization=aaa"
    result = clean(url)

    %w[hunter2 =abc =s =k 123456 xyz =sss =aaa].each { |secret| refute_includes result, secret }
    assert_includes result, "page=2", "parameters that are not sensitive stay"
    assert_includes result, "https://example.com/reset?"
  end

  test "long hex and base64-like secrets" do
    assert_redacts "key 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08 used", "9f86d081884c7d659a2feaa0c55ad015"
    assert_redacts "secret wJalrXUtnFEMIK7MDENGbPxRfiCYzEXAMPLEKEY used", "wJalrXUtnFEMIK7MDENGbPxRfiCY"
  end

  test "does not mangle backtraces, class names, dates, versions, ids, prices or prose" do
    [
      "app/controllers/users_controller.rb:123:in 'UsersController#show'",
      "/usr/local/bundle/gems/activerecord-8.1.4.1/lib/active_record/core.rb:262:in 'find'",
      "ActiveRecord::RecordNotFound: Couldn't find User with 'id'=42",
      "ActiveSupport::MessageVerifier::InvalidSignature",
      "Devise::Token::Error",
      "ActionDispatch::Cookies::CookieOverflow",
      "ActionController::InvalidAuthenticityToken",
      "deadline 2026-11-07 14:03:22 UTC",
      "at 2026-11-07T14:03:22.123+00:00",
      "due 07/11/2026 and 11/07/2026",
      "between 2025-2026",
      "request 9d1f6c2e-3b4a-4f5e-8a7b-1c2d3e4f5a6b",
      "Basic validation failed",
      "Session expired",
      "unexpected token at 'nil'",
      "undefined method 'create_table_with_a_really_long_name_for_users' for nil",
      "version 1.2.3, Rails 8.1.4.1, gem v2.10.0 and port 3000",
      "Order 12345 and order #123456789 and ORD-2026-0001 and id=42",
      "PID 12345 at line 1234 from 10.0.0.1 and 192.168.1.254",
      "total $1,234.56 or R$ 1.234,56 or 1.234.567,89 EUR or 1,234,567.89",
      "short sha 3f2a9c1"
    ].each { |text| assert_keeps text }
  end

  test "does not filter a value twice" do
    assert_equal "?token=[FILTERED]&page=2", clean("?token=abc&page=2")
  end

  test "accepts anything that becomes a string" do
    assert_equal "", clean(nil)
    assert_equal "42", clean(42)
  end

  # ---- country packs ---------------------------------------------------------

  test "without a pack, national documents are left to the global rules" do
    assert_keeps "CPF 123.456.789-09 and SSN 123-45-6789"
  end

  test "br: CPF, CNPJ (numeric and alphanumeric) and bare mobile numbers" do
    ENV["ERROR_SIGNAL_PII_RULES"] = "br"

    assert_redacts "CPF 123.456.789-09 invalid", "123.456.789-09"
    assert_redacts "CPF 123.456.789-01 invalid", "123.456.789-01" # formatted: filtered even with wrong check digits
    assert_redacts "CPF 12345678909 invalid", "12345678909"
    assert_redacts "CNPJ 11.222.333/0001-81 invalid", "11.222.333/0001-81"
    assert_redacts "CNPJ 11222333000181 invalid", "11222333000181"
    assert_redacts "CNPJ 12.ABC.345/01DE-35 invalid", "12.ABC.345/01DE-35"
    assert_redacts "CNPJ 12ABC34501DE35 invalid", "12ABC34501DE35"
    assert_redacts "call 11912345678 now", "11912345678"
    assert_redacts "call 5511912345678 now", "5511912345678"
  end

  test "br: bare numbers with wrong check digits are ids" do
    ENV["ERROR_SIGNAL_PII_RULES"] = "br"

    assert_keeps "order 12345678901 failed"
    assert_keeps "order 11222333000182 failed"
    assert_keeps "version 1.2.3 on 2026-11-07"
  end

  test "us: SSN and EIN" do
    ENV["ERROR_SIGNAL_PII_RULES"] = "us"

    assert_redacts "SSN 123-45-6789 invalid", "123-45-6789"
    assert_redacts "SSN 123 45 6789 invalid", "123 45 6789"
    assert_redacts "EIN 12-3456789 invalid", "12-3456789"
    assert_keeps "SSN 000-12-3456 and 666-12-3456 are never issued"
    assert_keeps "on 2026-11-07 at 14:03"
  end

  test "uk: National Insurance numbers" do
    ENV["ERROR_SIGNAL_PII_RULES"] = "uk"

    assert_redacts "NI AB 12 34 56 C invalid", "AB 12 34 56 C"
    assert_redacts "NI AB123456C invalid", "AB123456C"
    assert_keeps "prefix BG123456C and QQ123456C are not issued"
  end

  test "in: Aadhaar (Verhoeff) and PAN" do
    ENV["ERROR_SIGNAL_PII_RULES"] = "in"

    assert_redacts "Aadhaar 2345 6789 0124 invalid", "2345 6789 0124"
    assert_redacts "Aadhaar 234567890124 invalid", "234567890124"
    assert_keeps "order 234567890125 failed"
    assert_redacts "PAN ABCPE1234F invalid", "ABCPE1234F"
    assert_keeps "code ABCDE1234F is not a PAN"
  end

  test "eu: VAT numbers with their country prefix" do
    ENV["ERROR_SIGNAL_PII_RULES"] = "eu"

    %w[DE123456789 ATU12345678 NL123456789B01 ESX1234567X IE1234567WA BE0123456789 IT12345678901].each do |vat|
      assert_redacts "VAT #{vat} invalid", vat
    end
    assert_redacts "VAT FR 12 345678901 invalid", "345678901"
    assert_keeps "locale pt-BR, region DE and ES2026"
  end

  test "several packs at once, and unknown names are ignored" do
    ENV["ERROR_SIGNAL_PII_RULES"] = "br, US, xx"

    assert_equal %w[br us], ErrorSignal::Config.pii_rules
    assert_equal "CPF [FILTERED] and SSN [FILTERED]", clean("CPF 123.456.789-09 and SSN 123-45-6789")
  end

  # ---- check digits ----------------------------------------------------------

  test "check digit algorithms" do
    c = ErrorSignal::PII::Checksums

    assert c.luhn?("4111 1111 1111 1111")
    refute c.luhn?("4111 1111 1111 1112")
    refute c.luhn?("4111"), "too short for a card"
    assert c.iban?("GB82 WEST 1234 5698 7654 32")
    assert c.cpf?("123.456.789-09")
    refute c.cpf?("111.111.111-11"), "repeated digits are not a CPF"
    assert c.cnpj?("11.222.333/0001-81")
    assert c.cnpj?("12.ABC.345/01DE-35")
    assert c.verhoeff?("234567890124")
    refute c.verhoeff?("234567890125")
  end
end
