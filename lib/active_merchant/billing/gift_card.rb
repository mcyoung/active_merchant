module ActiveMerchant
  module Billing
    class GiftCard < CreditCard
      attr_accessor :pin
    end
  end
end