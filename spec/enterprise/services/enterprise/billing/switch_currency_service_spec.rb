require 'rails_helper'

describe Enterprise::Billing::SwitchCurrencyService do
  subject(:service) { described_class.new(account: account, currency: target_currency) }

  let(:account) { create(:account) }
  let(:target_currency) { 'brl' }
  let(:stripe_customer_id) { 'cus_test123' }
  let(:period_end) { 1.month.from_now.to_i }

  let(:active_subscription) do
    Stripe::Subscription.construct_from(
      id: 'sub_usd', status: 'active', quantity: 2, current_period_end: period_end,
      plan: { id: 'price_business_usd', product: 'prod_business' }, metadata: {}
    )
  end

  let(:new_subscription) do
    Stripe::Subscription.construct_from(
      id: 'sub_brl', status: 'trialing', quantity: 2, current_period_end: period_end,
      plan: { id: 'price_business_brl', product: 'prod_business' }, metadata: {}
    )
  end

  let(:invoice_settings) { Struct.new(:default_payment_method).new('pm_test') }
  let(:stripe_customer) { Struct.new(:invoice_settings, :default_source).new(invoice_settings, nil) }
  let(:default_payment_methods) { [Struct.new(:id, :type).new('pm_test', 'card')] }

  before do
    create(:installation_config, name: 'CHATWOOT_CLOUD_PLANS', value: [
             { 'name' => 'Hacker', 'product_id' => ['prod_hacker'], 'price_ids' => { 'usd' => ['price_hacker_usd'], 'brl' => ['price_hacker_brl'] } },
             { 'name' => 'Business', 'product_id' => ['prod_business'],
               'price_ids' => { 'usd' => ['price_business_usd'], 'brl' => ['price_business_brl'] } }
           ])

    account.enable_features!(:billing_currency_switch)
    account.update!(custom_attributes: { plan_name: 'Business', stripe_customer_id: stripe_customer_id, billing_currency: 'usd' })

    allow(Stripe::Subscription).to receive(:list).and_return(Struct.new(:data).new([active_subscription]))
    allow(Stripe::Subscription).to receive(:create).and_return(new_subscription)
    allow(Stripe::Subscription).to receive(:update)
    allow(Stripe::Subscription).to receive(:cancel)
    allow(Stripe::Customer).to receive(:retrieve).and_return(stripe_customer)
    allow(Stripe::Customer).to receive(:update)
    allow(Stripe::PaymentMethod).to receive(:list).and_return(Struct.new(:data).new(default_payment_methods))

    reconcile = instance_double(Enterprise::Billing::ReconcilePlanFeaturesService, perform: true)
    allow(Enterprise::Billing::ReconcilePlanFeaturesService).to receive(:new).and_return(reconcile)
  end

  describe '#perform' do
    it 'cancels the old subscription before creating the new-currency one' do
      service.perform

      expect(Stripe::Subscription).to have_received(:cancel).with('sub_usd', { prorate: false }).ordered
      expect(Stripe::Subscription).to have_received(:create).with(
        hash_including(customer: stripe_customer_id, items: [{ price: 'price_business_brl', quantity: 2 }]),
        hash_including(:idempotency_key)
      ).ordered
    end

    it 'uses a per-attempt idempotency key not derived from the subscription id' do
      service.perform

      expect(Stripe::Subscription).to have_received(:create).with(
        anything, hash_including(idempotency_key: a_string_matching(/\Aswitch-#{account.id}-[0-9a-f-]{36}\z/))
      )
    end

    it 'persists the new currency and clears the pending marker' do
      service.perform

      attributes = account.reload.custom_attributes
      expect(attributes['billing_currency']).to eq('brl')
      expect(attributes['stripe_price_id']).to eq('price_business_brl')
      expect(attributes).not_to have_key('billing_currency_switch_pending')
    end

    it 'tags the cancelled subscription so the webhook skips re-subscribing the default plan' do
      service.perform

      expect(Stripe::Subscription).to have_received(:update).with(
        'sub_usd', metadata: { described_class::SWITCH_METADATA_KEY => 'true' }
      )
    end

    it 'raises when the feature is not enabled' do
      account.disable_features!(:billing_currency_switch)

      expect { service.perform }.to raise_error do |error|
        expect(error.class.name).to eq('Enterprise::Billing::SwitchCurrencyService::Error')
        expect(error.message).to eq(I18n.t('errors.billing.currency_switch_unavailable'))
      end
    end

    it 'raises for an unsupported currency' do
      service = described_class.new(account: account, currency: 'eur')

      expect { service.perform }.to raise_error(described_class::Error, I18n.t('errors.billing.unsupported_currency'))
    end

    it 'raises when switching to the currency already in use' do
      service = described_class.new(account: account, currency: 'usd')

      expect { service.perform }.to raise_error(described_class::Error, I18n.t('errors.billing.same_currency'))
    end

    it 'raises when no stripe customer is configured' do
      account.update!(custom_attributes: { plan_name: 'Business', billing_currency: 'usd' })

      expect { service.perform }.to raise_error(described_class::Error, I18n.t('errors.billing.stripe_customer_not_configured'))
    end

    it 'raises when more than one live subscription exists' do
      allow(Stripe::Subscription).to receive(:list).and_return(Struct.new(:data).new([active_subscription, new_subscription]))

      expect { service.perform }.to raise_error(described_class::Error, I18n.t('errors.billing.switch_requires_active_subscription'))
    end

    it 'raises when the target currency is not configured for the plan' do
      InstallationConfig.find_by(name: 'CHATWOOT_CLOUD_PLANS').update!(value: [
                                                                         { 'name' => 'Business', 'product_id' => ['prod_business'],
                                                                           'price_ids' => { 'usd' => ['price_business_usd'] } }
                                                                       ])

      expect { service.perform }.to raise_error(described_class::Error, I18n.t('errors.billing.currency_not_available_for_plan'))
    end

    it 'completes the switch without a payment method (the user is prompted later)' do
      allow(Stripe::Customer).to receive(:retrieve).and_return(Struct.new(:invoice_settings, :default_source).new(
                                                                 Struct.new(:default_payment_method).new(nil), nil
                                                               ))
      allow(Stripe::PaymentMethod).to receive(:list).and_return(Struct.new(:data).new([]))

      expect { service.perform }.not_to raise_error
      expect(account.reload.custom_attributes['billing_currency']).to eq('brl')
    end

    context 'when creating the new-currency subscription fails' do
      before do
        # Only the new (brl) create fails; re-creating the original (usd) succeeds.
        allow(Stripe::Subscription).to receive(:create) do |params, _opts|
          raise Stripe::StripeError, 'cannot combine currencies' if params[:items].first[:price] == 'price_business_brl'

          active_subscription
        end
      end

      it 'cancels the old subscription then re-creates the original to restore service' do
        expect { service.perform }.to raise_error(described_class::Error)

        expect(Stripe::Subscription).to have_received(:cancel).with('sub_usd', { prorate: false })
        expect(Stripe::Subscription).to have_received(:create).with(
          hash_including(items: [{ price: 'price_business_usd', quantity: 2 }]), anything
        )
      end

      it 'keeps the account on the original currency and clears the pending marker' do
        expect { service.perform }.to raise_error(described_class::Error)

        attributes = account.reload.custom_attributes
        expect(attributes['billing_currency']).to eq('usd')
        expect(attributes).not_to have_key('billing_currency_switch_pending')
      end
    end

    context 'when a free default-plan subscription has a stale price id' do
      # Price id no longer in CHATWOOT_CLOUD_PLANS, but product_id still maps to the default (Hacker) plan.
      let(:active_subscription) do
        Stripe::Subscription.construct_from(
          id: 'sub_hacker', status: 'active', quantity: 1, current_period_end: period_end,
          plan: { id: 'price_hacker_legacy_usd', product: 'prod_hacker' }, metadata: {}
        )
      end
      let(:new_subscription) do
        Stripe::Subscription.construct_from(
          id: 'sub_hacker_brl', status: 'active', quantity: 1, current_period_end: period_end,
          plan: { id: 'price_hacker_brl', product: 'prod_hacker' }, metadata: {}
        )
      end

      before do
        account.update!(custom_attributes: { plan_name: 'Hacker', stripe_customer_id: stripe_customer_id, billing_currency: 'usd' })
        # No payment method available — a default-plan switch must not require one.
        allow(Stripe::Customer).to receive(:retrieve).and_return(
          Struct.new(:invoice_settings, :default_source).new(Struct.new(:default_payment_method).new(nil), nil)
        )
        allow(Stripe::PaymentMethod).to receive(:list).and_return(Struct.new(:data).new([]))
      end

      it 'switches without requiring a payment method or a paid-through trial' do
        service.perform

        expect(Stripe::Customer).not_to have_received(:retrieve)
        expect(Stripe::Subscription).to have_received(:create).with(hash_not_including(:trial_end), anything)
        expect(account.reload.custom_attributes['billing_currency']).to eq('brl')
      end
    end

    context 'when switching from brl to usd' do
      let(:target_currency) { 'usd' }
      let(:active_subscription) do
        Stripe::Subscription.construct_from(
          id: 'sub_brl', status: 'active', quantity: 2, current_period_end: period_end,
          plan: { id: 'price_business_brl', product: 'prod_business' }, metadata: {}
        )
      end
      let(:new_subscription) do
        Stripe::Subscription.construct_from(
          id: 'sub_usd', status: 'trialing', quantity: 2, current_period_end: period_end,
          plan: { id: 'price_business_usd', product: 'prod_business' }, metadata: {}
        )
      end

      before do
        account.update!(custom_attributes: { plan_name: 'Business', stripe_customer_id: stripe_customer_id, billing_currency: 'brl' })
      end

      it 'clears the stripe billing country and locale override' do
        service.perform

        expect(Stripe::Customer).to have_received(:update).with(
          stripe_customer_id, hash_including(address: { country: '' }, preferred_locales: [])
        )
        expect(account.reload.custom_attributes['billing_currency']).to eq('usd')
      end

      context 'when the default payment method cannot bill the new currency' do
        let(:pix) { Struct.new(:id, :type).new('pm_pix', 'pix') }
        let(:card) { Struct.new(:id, :type).new('pm_card', 'card') }

        before do
          allow(Stripe::Customer).to receive(:retrieve).and_return(
            Struct.new(:invoice_settings, :default_source).new(Struct.new(:default_payment_method).new('pm_pix'), nil)
          )
        end

        it 'switches the default to an attached compatible card' do
          allow(Stripe::PaymentMethod).to receive(:list).and_return(Struct.new(:data).new([pix, card]))

          service.perform

          expect(Stripe::Customer).to have_received(:update).with(stripe_customer_id, invoice_settings: { default_payment_method: 'pm_card' })
        end

        it 'unsets the default when no compatible method is attached' do
          allow(Stripe::PaymentMethod).to receive(:list).and_return(Struct.new(:data).new([pix]))

          service.perform

          expect(Stripe::Customer).to have_received(:update).with(stripe_customer_id, invoice_settings: { default_payment_method: '' })
          expect(account.reload.custom_attributes['billing_currency']).to eq('usd')
        end
      end
    end
  end
end
