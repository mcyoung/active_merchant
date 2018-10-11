require 'active_merchant/billing/gateways/amazon/amazon_response'

module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    class AmazonGateway < Gateway
      self.test_url = "https://mws.amazonservices.com/OffAmazonPayments_Sandbox/2013-01-01"
      self.live_url = "https://mws.amazonservices.com/OffAmazonPayments/2013-01-01"

      self.supported_countries = ['US']
      self.default_currency = 'USD'
      self.supported_cardtypes = [:visa, :master, :american_express, :discover]

      self.homepage_url = 'https://pay.amazon.com/us/developer/documentation'
      self.display_name = 'Amazon Pay Gateway'

      def initialize(options={})
        requires!(options, :aws_access_key, :aws_secret_key, :seller_id, :auto_capture)
        super
      end

      def fetch_order_data(ref_number)
        commit({
          "Action" => "GetOrderReferenceDetails",
          "AmazonOrderReferenceId" => ref_number
        })
      end

      def set_order_data(ref_number, total, currency)
        commit({
          "Action"=>"SetOrderReferenceDetails",
          "AmazonOrderReferenceId" => ref_number,
          "OrderReferenceAttributes.OrderTotal.Amount" => total,
          "OrderReferenceAttributes.OrderTotal.CurrencyCode" => currency
        })
      end

      def confirm_order(ref_number)
        commit({
          "Action"=>"ConfirmOrderReference",
          "AmazonOrderReferenceId" => ref_number
        })
      end

      def authorize(ref_number, total, currency)
        commit({
          "Action"=>"Authorize",
          "AmazonOrderReferenceId" => ref_number,
          "AuthorizationReferenceId" => "A#{Time.now.to_i}",
          "AuthorizationAmount.Amount" => total,
          "AuthorizationAmount.CurrencyCode" => currency,
          "CaptureNow" => @options[:auto_capture],
          "TransactionTimeout" => 0
        })
      end

      def get_authorization_details(ref_number)
        commit({
          "Action" => "GetAuthorizationDetails",
          "AmazonAuthorizationId" => ref_number
          })
      end

      def capture(auth_number, ref_number, total, currency)
        commit({
          "Action"=>"Capture",
          "AmazonAuthorizationId" => auth_number,
          "CaptureReferenceId" => ref_number,
          "CaptureAmount.Amount" => total,
          "CaptureAmount.CurrencyCode" => currency
        })
      end

      def get_capture_details(ref_number)
        commit({
          "Action" => "GetCaptureDetails",
          "AmazonCaptureId" => ref_number
          })
      end

      def refund(capture_id, ref_number, total, currency)
        commit({
          "Action"=>"Refund",
          "AmazonCaptureId" => capture_id,
          "RefundReferenceId" => ref_number,
          "RefundAmount.Amount" => total,
          "RefundAmount.CurrencyCode" => currency
        })
      end

      def get_refund_details(ref_number)
        commit({
          "Action" => "GetRefundDetails",
          "AmazonRefundId" => ref_number
          })
      end

      def close(ref_number)
        commit({
          "Action" => "CloseAuthorization",
          "AmazonAuthorizationId" => ref_number
          })
      end

      def purchase(ref_number, total, currency)
        response = authorize(ref_number, total, currency)
        capture(response.authorization, "C#{Time.now.to_i}", total, currency)
      end

      def build_request_body(hash)
        hash = default_hash.reverse_merge(hash)
        query_string = hash.sort.map { |k, v| "#{k}=#{ custom_escape(v) }" }.join("&")
        message = ["POST", "mws.amazonservices.com", "/#{sandbox_str}/2013-01-01", query_string].join("\n")
        query_string += "&Signature=" + custom_escape(Base64.encode64(OpenSSL::HMAC.digest(OpenSSL::Digest::SHA256.new, @options[:aws_secret_key], message)).strip)
      end

      private

      def url
        (test? ? test_url : live_url)
      end

      def sandbox_str
        if test?
          'OffAmazonPayments_Sandbox'
        else
          'OffAmazonPayments'
        end
      end

      def default_hash
        {
          "AWSAccessKeyId"=>@options[:aws_access_key],
          "SellerId"=>@options[:seller_id],
          "PlatformId"=>"A31NP5KFHXSFV1",
          "SignatureMethod"=>"HmacSHA256",
          "SignatureVersion"=>"2",
          "Timestamp"=>Time.now.utc.iso8601,
          "Version"=>"2013-01-01"
        }
      end

      def custom_escape(val)
        val.to_s.gsub(/([^\w.~-]+)/) do
          "%" + $1.unpack("H2" * $1.bytesize).join("%").upcase
        end
      end

      def parse(raw)
        doc = Nokogiri::XML(clean_response_from(raw))
        doc.remove_namespaces!
        response = Hash.from_xml(doc.to_xml)

        if(detail = response.dig("GetOrderReferenceDetailsResponse", "GetOrderReferenceDetailsResult"))
          response = detail
        end

        if(fault = response.dig("ErrorResponse", "Error", "Message"))
          response["Fault"] = fault
        end

        response
      end

      def commit(parameters)
        data = build_request_body(parameters)

        response = begin
          parse( ssl_post(url, data) )
        rescue ResponseError => e
          parse(e.response.body)
        end

        ActiveMerchant::Billing::AmazonResponse.new(
          success_from(response),
          message_from(response),
          response,
          authorization: authorization_from(response) || capture_id_from(response),
          authorized_amt: total_from(response) || authorized_amount_from(response),
          destination: destination_from(response),
          constraints: constraints_from(response),
          state: status_from(response) || capture_state_from(response),
          test: test?,
        )
      end

      def success_from(response)
        response["Fault"].blank?
      end

      def message_from(response)
        if response["Fault"]
          response["Fault"]
        elsif constraints_from(response)
          constraints_from(response)
        elsif status_message_from(response)
          status_message_from(response)
        end
      end

      def authorization_from(response)
        response.fetch("AuthorizeResponse", {}).fetch("AuthorizeResult", {}).fetch("AuthorizationDetails", {}).fetch("AmazonAuthorizationId", nil)
      end

      def authorized_amount_from(response)
        response.fetch("AuthorizeResponse", {}).fetch("AuthorizeResult", {}).fetch("AuthorizationDetails", {}).fetch("AuthorizationAmount", {}).fetch("Amount", nil)
      end

      def status_from(response)
        response.fetch("OrderReferenceDetails", {}).fetch("OrderReferenceStatus", {}).fetch("State", nil)
      end

      def status_message_from(response)
        response.fetch("OrderReferenceDetails", {}).fetch("OrderReferenceStatus", {}).fetch("ReasonCode", nil)
      end

      def constraints_from(response)
        response.fetch("OrderReferenceDetails", {}).fetch("Constraints", {}).fetch("Constraint", {}).fetch("Description", nil)
      end

      def destination_from(response)
        response.fetch("OrderReferenceDetails", {}).fetch("OrderReferenceDetails", {}).fetch("Destination", nil)
      end

      def capture_id_from(response)
        response.fetch("CaptureResponse", {}).fetch("CaptureResult", {}).fetch("CaptureDetails", {}).fetch("AmazonCaptureId", nil)
      end

      def capture_state_from(response)
        response.fetch("CaptureResponse", {}).fetch("CaptureResult", {}).fetch("CaptureDetails", {}).fetch("CaptureStatus", {}).fetch("State", nil)
      end

      def total_from(response)
        total_block = response.fetch("OrderReferenceDetails", {}).fetch("OrderTotal", {})
        total_block.fetch("Amount", nil)
      end

      def clean_response_from(response)
        response.gsub!("\n", "")
        response.gsub!(/\s{2,}/, "")

        response
      end
    end
  end
end