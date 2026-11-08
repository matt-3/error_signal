# frozen_string_literal: true

# Source read by the code line tests (details_test.rb). Its line numbers are
# part of the tests: keep the charge on line 9.
class Checkout
  def call(order)
    total = order.total
    gateway = order.gateway
    gateway.charge!(total, customer: "joao@example.com")
    order.paid!
    order
  end
end
