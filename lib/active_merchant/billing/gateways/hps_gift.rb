module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    class HpsGiftGateway < HpsGateway

      self.supported_cardtypes = [:hps_gift]

      def initialize(options={})
        requires!(options, :secret_api_key)
        super
      end

      def activate(giftcard, amount, currency = "USD")
        commit('GiftCardActivate') do |xml|
          add_amount(xml, amount)
          add_card_data(xml, giftcard)
        end
      end

      def add_value(giftcard, amount, currency = "USD")
        commit('GiftCardAddValue') do |xml|
          add_amount(xml, amount)
          add_card_data(xml, giftcard)
        end
      end

      def balance(giftcard)
        commit('GiftCardBalance') do |xml|
          add_card_data(xml, giftcard)
        end
      end

      def authorize(giftcard, amount, currency = "USD")
        # Check the card balance and authorize an amount equal
        # to the amount provided or the balance of the card.
        response = balance(giftcard)
        available_balance = (response.balance_amt.to_f * 100).round

        if available_balance >= amount
          authorized_amount = amount(amount)
        else
          authorized_amount = amount(available_balance)
        end

        auth = ActiveMerchant::Billing::Response.new(
          successful?(response.params),
          message_from(response.params),
          response.params,
          test: test?,
          authorization: authorization_from(response.params),
          balance_amt: response.balance_amt,
          authorized_amt: authorized_amount
        )
        return auth
      end

      def capture(giftcard, amount, currency = "USD", options = {})
        # TODO: This should probably take an object that holds an auth amt (balance)
        # and check that the charge amount does not exceed the auth amt and then
        # execute a sale against the card. Or it should just do the sale.
        commit('GiftCardSale') do |xml|
          add_amount(xml, amount)
          add_card_data(xml, giftcard)

          if ["USD", "POINTS"].include? currency.upcase
            xml.hps :Currency, currency.upcase
          end

          if options.key? :gratuity
            xml.hps :GratuityAmtInfo, amount(options[:gratuity])
          end

          if options.key? :tax
            xml.hps :TaxAmtInfo, amount(options[:tax])
          end
        end
      end

      def purchase(giftcard, amount, currency = "USD", options={})
        # TODO: This should combine the authorize and capture methods.
        # It should capture the amount indicated by the auth method.
        authorized_amount = authorize(giftcard, amount, currency).authorized_amt
        authorized_amount_in_cents = (authorized_amount.to_f * 100).round
        capture(giftcard, authorized_amount_in_cents, currency)
      end

      def refund(money, authorization, options={})
        # commit('refund', post)
      end

      def void(authorization, options={})
        # commit('void', post)
      end

      def supports_scrubbing?
        # true
      end

      def scrub(transcript)
        # transcript
      end

      private

      def add_customer_data(post, options)
      end

      def add_address(post, creditcard, options)
      end

      def add_invoice(post, money, options)
        # post[:amount] = amount(money)
        # post[:currency] = (options[:currency] || currency(money))
      end

      def add_payment(post, payment)
      end


      def commit(action, &request)
        data = build_request(action, &request)

        response = begin
          parse(ssl_post((test? ? test_url : live_url), data, 'Content-type' => 'text/xml'))
        rescue ResponseError => e
          parse(e.response.body)
        end

        ActiveMerchant::Billing::Response.new(
          successful?(response),
          message_from(response),
          response,
          test: test?,
          authorization: authorization_from(response),
          balance_amt: response['BalanceAmt']
        )
      end

      # HPS Gift response codes use sing "0" versus HPS Credit's "00"
      def successful?(response)
        (response["GatewayRspCode"] == "0") && ((response["RspCode"] || "0") == "0")
      end

      def message_from(response)
        if(response["Fault"])
          response["Fault"]
        elsif(response["GatewayRspCode"] == "0")
          if(response["RspCode"] != "0")
            issuer_message(response["RspCode"])
          else
            response['GatewayRspMsg']
          end
        else
          (GATEWAY_MESSAGES[response["GatewayRspCode"]] || response["GatewayRspMsg"])
        end
      end

      def add_card_data(xml, giftcard, element_name = 'CardData')
        xml.hps element_name.to_sym do
          xml.hps :CardNbr, giftcard.number

          if giftcard.pin
            xml.hps :PIN, giftcard.pin.to_s
          end
        end
      end # hydrate_gift_card_data

      def build_request(action)
        xml = Builder::XmlMarkup.new(encoding: 'UTF-8')
        xml.instruct!(:xml, encoding: 'UTF-8')
        xml.SOAP :Envelope, {
            'xmlns:SOAP' => 'http://schemas.xmlsoap.org/soap/envelope/',
            'xmlns:hps' => 'http://Hps.Exchange.PosGateway' } do
          xml.SOAP :Body do
            xml.hps :PosRequest do
              xml.hps 'Ver1.0'.to_sym do
                xml.hps :Header do
                  xml.hps :SecretAPIKey, @options[:secret_api_key]
                  xml.hps :DeveloperID, @options[:developer_id] if @options[:developer_id]
                  xml.hps :VersionNbr, @options[:version_number] if @options[:version_number]
                  xml.hps :SiteTrace, @options[:site_trace] if @options[:site_trace]
                end
                xml.hps :Transaction do
                  xml.hps action.to_sym do
                    if %w(CreditVoid CreditAddToBatch).include?(action)
                      yield(xml)
                    else
                      xml.hps :Block1 do
                        yield(xml)
                      end
                    end
                  end
                end
              end
            end
          end
        end
        xml.target!
      end # build_request

      # Override the HPS codes and messages as they are different for gift cards
      ISSUER_MESSAGES = {
        "9" => "Must be greater than or equal 0.",
        "4" => "The card has expired.",
        "14" => "The 4-digit pin is invalid.",
        "13" => "The amount was partially approved."
      }
      def issuer_message(code)
        return "The card was declined." if %w(5 12).include?(code)
        return "An error occurred while processing the card." if %w(6 7 10).include?(code)
        return "Invalid card data." if %w(3 8).include?(code)
        ISSUER_MESSAGES[code] || "Unknown issuer error."
      end

      GATEWAY_MESSAGES = {
        "-2" => "Authentication error. Please double check your service configuration.",
        "12" => "Invalid CPC data.",
        "13" => "Invalid card data.",
        "14" => "The card number is not a valid credit card number.",
        "30" => "Gateway timed out."
      }
    end
  end
end