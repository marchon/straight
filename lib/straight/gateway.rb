module Straight

  # This module should be included into your own class to extend it with Gateway functionality.
  # For example, if you have a ActiveRecord model called Gateway, you can include GatewayModule into it
  # and you'll now be able to do everything Straight::Gateway can do, but you'll also get AR Database storage
  # funcionality, its validations etc.
  #
  # The right way to implement this would be to do it the other way: inherit from Straight::Gateway, then
  # include ActiveRecord, but at this point ActiveRecord doesn't work this way. Furthermore, some other libraries, like Sequel,
  # also require you to inherit from them. Thus, the module.
  #
  # When this module is included, it doesn't actually *include* all the methods, some are prepended (see Ruby docs on #prepend).
  # It is important specifically for getters and setters and as a general rule only getters and setters are prepended.
  #
  # If you don't want to bother yourself with modules, please use Straight::Gateway class and simply create new instances of it.
  # However, if you are contributing to the library, all new funcionality should go to either Straight::GatewayModule::Includable or
  # Straight::GatewayModule::Prependable (most likely the former).
  module GatewayModule

    # Only add getters and setters for those properties in the extended class
    # that don't already have them. This is very useful with ActiveRecord for example
    # where we don't want to override AR getters and setters that set attributes.
    def self.included(base)
      base.class_eval do
        [
          :pubkey,
          :confirmations_required,
          :status_check_schedule,
          :blockchain_adapters,
          :exchange_rate_adapters,
          :order_callbacks,
          :order_class,
          :default_currency,
          :name
        ].each do |field|
          attr_reader field unless base.method_defined?(field)
          attr_writer field unless base.method_defined?("#{field}=")
          prepend Prependable
          include Includable
        end
      end
    end

    # Determines the algorithm for consequitive checks of the order status.
    DEFAULT_STATUS_CHECK_SCHEDULE = -> (period, iteration_index) do
      iteration_index += 1
      if iteration_index > 5
        period          *= 2
        iteration_index  = 0
      end
      return { period: period, iteration_index: iteration_index }
    end

    # If you are defining methods in this module, it means you most likely want to
    # call super() somehwere inside those methods.
    #
    # In short, the idea is to let the class we're being prepended to do its magic
    # after our methods are finished.
    module Prependable
    end

    module Includable

      # Creates a new order for the address derived from the pubkey and the keychain_id argument provided.
      # See explanation of this keychain_id argument is in the description for the #address_for_keychain_id method.
      def order_for_keychain_id(amount:, keychain_id:, currency: nil, btc_denomination: :satoshi)

        amount = amount_from_exchange_rate(
          amount,
          currency:         currency,
          btc_denomination: btc_denomination
        )

        order             = Kernel.const_get(order_class).new
        order.amount      = amount
        order.gateway     = self
        order.address     = address_for_keychain_id(keychain_id)
        order.keychain_id = keychain_id
        order
      end

      # Returns a Base58-encoded Bitcoin address to which the payment transaction
      # is expected to arrive. id is an an integer > 0 (hopefully not too large and hopefully
      # the one a user of this class is going to properly increment) that is used to generate a
      # an BIP32 bitcoin address deterministically.
      def address_for_keychain_id(id)
        keychain.node_for_path(id.to_s).to_address
      end
      
      def fetch_transaction(tid, address: nil)
        try_adapters(@blockchain_adapters) { |b| b.fetch_transaction(tid, address: address) }
      end
      
      def fetch_transactions_for(address)
        try_adapters(@blockchain_adapters) { |b| b.fetch_transactions_for(address) }
      end
      
      def fetch_balance_for(address)
        try_adapters(@blockchain_adapters) { |b| b.fetch_balance_for(address) }
      end

      def keychain
        @keychain ||= MoneyTree::Node.from_serialized_address(pubkey)
      end

      # This is a callback method called from each order
      # whenever an order status changes.
      def order_status_changed(order)
        @order_callbacks.each do |c|
          c.call(order)
        end
      end

      # Gets exchange rates from one of the exchange rate adapters,
      # then calculates how much BTC does the amount in the given currency represents.
      # 
      # You can also feed this method various bitcoin denominations.
      # It will always return amount in Satoshis.
      def amount_from_exchange_rate(amount, currency:, btc_denomination: :satoshi)
        currency         = self.default_currency if currency.nil?
        btc_denomination = :satoshi              if btc_denomination.nil?
        currency = currency.to_s.upcase
        if currency == 'BTC'
          return Satoshi.new(amount, from_unit: btc_denomination).to_i
        end

        try_adapters(@exchange_rate_adapters) do |a|
          a.convert_from_currency(amount, currency: currency)
        end
      end

      private
        
        # Calls the block with each adapter until one of them does not fail.
        # Fails with the last exception.
        def try_adapters(adapters, &block)
          last_exception = nil
          adapters.each do |adapter|
            begin
              result = yield(adapter)
              last_exception = nil
              return result
            rescue Exception => e
              last_exception = e
              # If an Exception is raised, it passes on
              # to the next adapter and attempts to call a method on it.
            end
          end
          raise last_exception if last_exception
        end

    end

  end


  class Gateway

    include GatewayModule

    def initialize
      @default_currency = 'BTC'
      @blockchain_adapters = [
        Blockchain::BlockchainInfoAdapter.mainnet_adapter,
        Blockchain::HelloblockIoAdapter.mainnet_adapter
      ]
      @exchange_rate_adapters = [
        ExchangeRate::BitpayAdapter.new,
        ExchangeRate::CoinbaseAdapter.new,
        ExchangeRate::BitstampAdapter.new
      ]
      @status_check_schedule = DEFAULT_STATUS_CHECK_SCHEDULE
    end

    def order_class
      "Straight::Order"
    end

  end

end
