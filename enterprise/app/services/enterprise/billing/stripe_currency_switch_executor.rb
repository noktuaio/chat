# Performs the Stripe-side currency switch: sync the customer location, create the new-currency
# subscription, then cancel the old one. Stripe can't change a subscription's currency in place and
# can't prorate across currencies, so the switch is a cancel + recreate. Creating the new sub *before*
# cancelling the old one means any failure leaves the customer on their original subscription rather
# than with none — the whole operation self-reverts.
class Enterprise::Billing::StripeCurrencySwitchExecutor
  class Error < StandardError; end

  pattr_initialize [:account!, :target_currency!]

  # Returns the newly-created Stripe subscription.
  def execute(subscription:, change:)
    validate_payment_method! unless Enterprise::Billing::PlanConfiguration.default_price?(subscription['plan']['id'])

    previous_currency = account.billing_currency
    sync_customer_location(target_currency)

    begin
      replace_subscription(subscription, change)
    rescue StandardError
      # The subscription swap reverted to the old currency — undo the customer location change too.
      sync_customer_location(previous_currency)
      raise
    end
  end

  private

  def replace_subscription(subscription, change)
    new_subscription = create_currency_subscription(change[:new_price_id], change)
    cancel_old_subscription(subscription, new_subscription)
    new_subscription
  rescue Stripe::StripeError => e
    raise Error, e.message
  end

  def cancel_old_subscription(old_subscription, new_subscription)
    cancel_subscription(old_subscription)
  rescue Stripe::StripeError
    # Couldn't retire the old sub: cancel the just-created one so the customer keeps a single subscription.
    Stripe::Subscription.cancel(new_subscription.id, { prorate: false })
    raise
  end

  def cancel_subscription(subscription)
    Stripe::Subscription.update(subscription.id, metadata: { Enterprise::Billing::SwitchCurrencyService::SWITCH_METADATA_KEY => 'true' })
    Stripe::Subscription.cancel(subscription.id, { prorate: false })
  rescue Stripe::StripeError
    # Clear the flag so a still-live sub isn't permanently skipped by the webhook guard.
    Stripe::Subscription.update(subscription.id, metadata: { Enterprise::Billing::SwitchCurrencyService::SWITCH_METADATA_KEY => '' })
    raise
  end

  def create_currency_subscription(price_id, change)
    params = { customer: stripe_customer_id, items: [{ price: price_id, quantity: change[:quantity] }] }
    # trial_end preserves the already-paid time so switching mid-cycle doesn't double-charge.
    params[:trial_end] = change[:paid_through] if change[:paid_through].present? && change[:paid_through] > Time.current.to_i
    Stripe::Subscription.create(params, { idempotency_key: "switch-#{account.id}-#{change[:key]}" })
  end

  def validate_payment_method!
    customer = Stripe::Customer.retrieve(stripe_customer_id)
    return if customer.invoice_settings.default_payment_method.present? || customer.default_source.present?

    payment_methods = Stripe::PaymentMethod.list(customer: stripe_customer_id, limit: 1)
    raise Error, I18n.t('errors.billing.no_payment_method') if payment_methods.data.empty?

    Stripe::Customer.update(stripe_customer_id, invoice_settings: { default_payment_method: payment_methods.data.first.id })
  end

  # Only currencies that need a country override (e.g. BRL/PIX) push an address/locale to Stripe;
  # usd keeps Stripe's defaults, matching how the customer is first created.
  def sync_customer_location(currency_code)
    country = Enterprise::Billing::Currencies.country_for(currency_code)
    return if country.blank?

    Stripe::Customer.update(
      stripe_customer_id,
      address: { country: country },
      preferred_locales: [Enterprise::Billing::Currencies.preferred_locale_for(currency_code)]
    )
  end

  def stripe_customer_id
    account.custom_attributes['stripe_customer_id']
  end
end
