# frozen_string_literal: true

require "test_helper"

# ERROR_SIGNAL_MASK=partial (the default): personal data keeps the part that
# tells which record failed; secrets are always filtered whole.
class MaskTest < ActiveSupport::TestCase
  DOT = ErrorSignal::Sanitizer::Mask::DOT

  setup do
    @original = ENV.to_h.slice("ERROR_SIGNAL_PII_RULES", "ERROR_SIGNAL_MASK")
    ENV["ERROR_SIGNAL_PII_RULES"] = "br,us,uk,in,eu"
    ENV.delete("ERROR_SIGNAL_MASK")
  end

  teardown do
    %w[ERROR_SIGNAL_PII_RULES ERROR_SIGNAL_MASK].each { |name| ENV.delete(name) }
    @original.each { |name, value| ENV[name] = value }
  end

  def clean(text)
    ErrorSignal::Sanitizer.call(text)
  end

  # "•" written as "*" in the expectations, for readability.
  def assert_masks(expected, text)
    assert_equal expected.tr("*", DOT), clean(text), text
  end

  test "partial is the default" do
    assert_equal "partial", ErrorSignal::Config.mask
    ENV["ERROR_SIGNAL_MASK"] = "anything"
    assert_equal "partial", ErrorSignal::Config.mask
    ENV["ERROR_SIGNAL_MASK"] = " FULL "
    assert_equal "full", ErrorSignal::Config.mask
  end

  test "CPF keeps the six middle digits" do
    assert_masks "CPF ***.456.789-** inválido", "CPF 123.456.789-09 inválido"
    assert_masks "CPF ***456789** inválido", "CPF 12345678909 inválido"
  end

  test "an order id with wrong check digits stays whole" do
    assert_masks "pedido 12345678901 falhou", "pedido 12345678901 falhou"
  end

  test "CNPJ keeps six digits of the root and the branch, never only 0001" do
    assert_masks "CNPJ **.345.678/0001-**", "CNPJ 12.345.678/0001-95"
    assert_masks "CNPJ **2223330001**", "CNPJ 11222333000181"
    assert_masks "CNPJ **.ABC.345/01DE-**", "CNPJ 12.ABC.345/01DE-35"
  end

  test "e-mails keep the first letter and the domain, with a fixed number of dots" do
    assert_masks "user j***@gmail.com not found", "user joao.silva@gmail.com not found"
    assert_masks "user a***@b.co", "user a@b.co"
  end

  test "cards, phones and national ids keep their last four" do
    {
      "card 4111 1111 1111 1111" => "card **** **** **** 1111",
      "card 4111111111111111" => "card ************1111",
      "call +55 11 91234-5678 on 2026-11-07" => "call +** ** *****-5678 on 2026-11-07",
      "(11) 91234-5678" => "(**) *****-5678",
      "415-555-2671" => "***-***-2671",
      "ligar 11912345678" => "ligar *******5678",
      "020 7946 0958" => "*** **** 0958",
      "SSN 123-45-6789" => "SSN ***-**-6789",
      "EIN 12-3456789" => "EIN **-***6789",
      "NI AB 12 34 56 C" => "NI ** ** *4 56 C",
      "Aadhaar 2345 6789 0124" => "Aadhaar **** **** 0124",
      "PAN ABCPE1234F" => "PAN ******234F"
    }.each { |text, expected| assert_masks expected, text }
  end

  test "a short number never shows more than half of its digits" do
    assert_masks "***-*671", "555-2671"
  end

  test "IBAN and VAT keep the country and the last four" do
    assert_masks "IBAN GB** **** **** **** **54 32", "IBAN GB82 WEST 1234 5698 7654 32"
    assert_masks "VAT DE*****6789", "VAT DE123456789"
  end

  test "secrets are filtered whole in partial mode too" do
    {
      "password=hunter2 token=abc" => "password=[FILTERED] token=[FILTERED]",
      "Authorization: Bearer abcdefghijklmnop" => "Authorization: [FILTERED]",
      "Bearer abcdefghijklmnop" => "Bearer [FILTERED]",
      "key #{%w[sk live abcdefghijkl].join('_')}" => "key [FILTERED]",
      "jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.sig" => "jwt [FILTERED]",
      "hash 0123456789abcdef0123456789abcdef" => "hash [FILTERED]",
      "url https://discord.com/api/webhooks/123/abc-def" => "url [FILTERED]",
      "/reset?token=abc123&page=2" => "/reset?token=[FILTERED]&page=2"
    }.each { |text, expected| assert_equal expected, clean(text), text }
  end

  test "full turns personal data into [FILTERED] whole" do
    ENV["ERROR_SIGNAL_MASK"] = "full"
    assert_equal "CPF [FILTERED], [FILTERED], [FILTERED], [FILTERED], CNPJ [FILTERED]",
      clean("CPF 123.456.789-09, joao@gmail.com, 4111 1111 1111 1111, +55 11 91234-5678, CNPJ 12.345.678/0001-95")
  end

  test "a masked value is not masked again by a later rule" do
    text = "CPF 123.456.789-09, CNPJ 12.345.678/0001-95, card 4111 1111 1111 1111, tel (11) 91234-5678"
    once = clean(text)
    assert_equal once, clean(once)
  end
end
