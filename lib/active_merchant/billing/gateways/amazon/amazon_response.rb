module ActiveMerchant
  module Billing
    class AmazonResponse < Response
      attr_reader :constraints, :state, :destination, :email, :total

      def initialize(success, message, params = {}, options = {})
        @constraints = options[:constraints]
        @state = options[:state]
        @destination = options[:destination]
        @email = options[:email]
        @total = options[:total]
        super(success, message, params, options)
      end
    end
  end
end