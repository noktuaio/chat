# Performs the Stripe-side currency switch: sync the customer location, cancel the old-currency
# subscription, then create the new-currency one. Stripe can't change a subscription's currency in
# place, can't prorate across currencies, and forbids two currencies on a single customer — so the old
# subscription must be cancelled *before* the new one can be created. If the create fails afterwards we
# re-create the original (its currency is free again) so the customer isn't left without a subscription.
class Enterprise::Billing::StripeCurrencySwitchExecutor
  class Error < StandardError; end

  pattr_initialize [:account!, :target_currency!]

  # Returns the newly-created Stripe subscription.
  def execute(subscription:, change:)
    reconcile_default_payment_method unless change[:default_plan]

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
    cancel_subscription(subscription)
    create_or_revert(change)
  rescue Stripe::StripeError => e
    # Reaches here only if cancel itself failed (old sub still active) or the revert create failed.
    raise Error, e.message
  end

  def create_or_revert(change)
    create_currency_subscription(change[:new_price_id], change, idempotency_key)
  rescue Stripe::StripeError
    # Old sub is already cancelled; re-create the original so the customer keeps a subscription, then
    # surface the original failure.
    create_currency_subscription(change[:original_price_id], change, revert_idempotency_key)
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

  def create_currency_subscription(price_id, change, idempotency_key)
    params = { customer: stripe_customer_id, items: [{ price: price_id, quantity: change[:quantity] }] }
    # trial_end preserves the already-paid time so switching mid-cycle doesn't double-charge.
    params[:trial_end] = change[:paid_through] if change[:paid_through].present? && change[:paid_through] > Time.current.to_i
    Stripe::Subscription.create(params, { idempotency_key: idempotency_key })
  end

  # Distinct keys per switch attempt: a retry must never replay a cancelled subscription, and the
  # revert create must never be conflated with the forward create.
  def attempt_token
    @attempt_token ||= SecureRandom.uuid
  end

  def idempotency_key
    "switch-#{account.id}-#{attempt_token}"
  end

  def revert_idempotency_key
    "switch-revert-#{account.id}-#{attempt_token}"
  end

  # Drop a default that can't bill the new currency (e.g. PIX on a USD switch) and pick a compatible one
  # if attached; leaving none is fine — the user is prompted to add a method before the next charge.
  def reconcile_default_payment_method
    Enterprise::Billing::DefaultPaymentMethodReconciler.new(account: account, currency: target_currency).reconcile
  end

  # Currencies that need a country override (e.g. BRL/PIX) push it to Stripe; for currencies without
  # one (usd) we clear any prior override so the customer matches how a usd customer is first created
  # — otherwise switching away from BRL would leave a stale BR/pt-BR address on the customer.
  def sync_customer_location(currency_code)
    country = Enterprise::Billing::Currencies.country_for(currency_code)
    locale = Enterprise::Billing::Currencies.preferred_locale_for(currency_code)

    Stripe::Customer.update(
      stripe_customer_id,
      address: { country: country.presence || '' },
      preferred_locales: locale.present? ? [locale] : []
    )
  end

  def stripe_customer_id
    account.custom_attributes['stripe_customer_id']
  end
end
