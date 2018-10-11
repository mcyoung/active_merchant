module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    class AmazonPayGateway < Gateway

      def initialize(options={})
        requires!(options, :some_credential, :another_credential)
        super
      end

      def purchase(amount, amazon_checkout, gateway_options={})
        authorize(amount, amazon_checkout, gateway_options)
        capture(amount, amazon_checkout, gateway_options)
      end

      def authorize(amount, amazon_checkout, gateway_options={})
        if amount < 0
          return ActiveMerchant::Billing::Response.new(true, "Success", {})
        end
        order = Spree::Order.find_by(:number => gateway_options[:order_id].split("-")[0])
        load_amazon_mws(order.amazon_order_reference_id)
        response = @mws.authorize(gateway_options[:order_id], amount / 100.0, "USD")
        if response["ErrorResponse"]
          return ActiveMerchant::Billing::Response.new(false, response["ErrorResponse"]["Error"]["Message"], response)
        end
        t = order.amazon_transaction
        t.authorization_id = response["AuthorizeResponse"]["AuthorizeResult"]["AuthorizationDetails"]["AmazonAuthorizationId"]
        t.save
        return ActiveMerchant::Billing::Response.new(response["AuthorizeResponse"]["AuthorizeResult"]["AuthorizationDetails"]["AuthorizationStatus"]["State"] == "Open", "Success", response)
      end

      def capture(amount, amazon_checkout, gateway_options={})
        if amount < 0
          return credit(amount.abs, nil, nil, gateway_options)
        end
        order = Spree::Order.find_by(:number => gateway_options[:order_id].split("-")[0])
        load_amazon_mws(order.amazon_order_reference_id)

        authorization_id = order.amazon_transaction.authorization_id
        response = @mws.capture(authorization_id, "C#{Time.now.to_i}", amount / 100.00, "USD")
        t = order.amazon_transaction
        t.capture_id = response.fetch("CaptureResponse", {}).fetch("CaptureResult", {}).fetch("CaptureDetails", {}).fetch("AmazonCaptureId", nil)
        t.save!
        return ActiveMerchant::Billing::Response.new(response.fetch("CaptureResponse", {}).fetch("CaptureResult", {}).fetch("CaptureDetails", {}).fetch("CaptureStatus", {})["State"] == "Completed", "OK", response)
      end

      def credit(amount, _credit_card, gateway_options={})
        order = Spree::Order.find_by(:number => gateway_options[:order_id].split("-")[0])
        load_amazon_mws(order.amazon_order_reference_id)
        capture_id = order.amazon_transaction.capture_id
        response = @mws.refund(capture_id, gateway_options[:order_id], amount / 100.00, "USD")
        return ActiveMerchant::Billing::Response.new(true, "Success", response)
      end

      def void(response_code, gateway_options)
        order = Spree::Order.find_by(:number => gateway_options[:order_id].split("-")[0])
        load_amazon_mws(order.amazon_order_reference_id)
        capture_id = order.amazon_transaction.capture_id
        response = @mws.refund(capture_id, gateway_options[:order_id], order.total, "USD")
        return ActiveMerchant::Billing::Response.new(true, "Success", response)
      end

      def close(amount, amazon_checkout, gateway_options={})
        order = Spree::Order.find_by(:number => gateway_options[:order_id].split("-")[0])
        load_amazon_mws(order.amazon_order_reference_id)

        authorization_id = order.amazon_transaction.authorization_id
        response = @mws.close(authorization_id)
        return ActiveMerchant::Billing::Response.new(true, "Success", response)
      end

      private

      def load_amazon_mws(reference)
        @mws ||= AmazonMws.new(reference, self.preferred_test_mode)
      end
    end
  end
end