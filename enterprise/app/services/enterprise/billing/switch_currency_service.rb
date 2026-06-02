class Enterprise::Billing::SwitchCurrencyService
  include BillingHelper

  class Error < StandardError; end

  # Tagged on a subscription right before we cancel it for a currency switch, so
  # the customer.subscription.deleted webhook knows NOT to re-subscribe the
  # default plan (which would create a stray Hacker sub and block the new
  # currency). Read by HandleStripeEventService#process_subscription_deleted.
  SWITCH_METADATA_KEY = 'chatwoot_currency_switch'.freeze

  pattr_initialize [:account!, :currency!]

  def perform
    validate!

    subscriptions = live_subscriptions
    paid_subscription = subscriptions.find { |subscription| !default_price?(subscription) }

    if paid_subscription
      switch_paid_plan(subscriptions, paid_subscription)
    else
      switch_free_plan
    end
  end

  private

  def target_currency
    @target_currency ||= Enterprise::Billing::Currencies.normalize(currency)
  end

  def validate!
    raise Error, I18n.t('errors.billing.unsupported_currency') unless Enterprise::Billing::Currencies.supported?(currency)
    raise Error, I18n.t('errors.billing.same_currency') if target_currency == account.billing_currency
    raise Error, I18n.t('errors.billing.stripe_customer_not_configured') if stripe_customer_id.blank?
  end

  # Free plan ($0): no subscription churn — just record the preference and keep
  # the Stripe customer location/currency in sync for future upgrades/top-ups.
  def switch_free_plan
    sync_stripe_customer_location
    persist_currency(account.custom_attributes.merge('billing_currency' => target_currency))
  end

  # Cancel every live subscription and create ONE subscription for the current
  # paid plan in the target currency, preserving the seat count and the
  # already-paid-through date. Decisions are based on the actual Stripe state
  # (not stored attributes) so a messy/duplicated state converges to a single
  # correct subscription.
  def switch_paid_plan(subscriptions, paid_subscription)
    validate_payment_method!

    plan = current_plan(paid_subscription)
    raise Error, I18n.t('errors.billing.unknown_plan') if plan.blank?

    change = {
      new_price_id: resolve_new_price_id(plan),
      original_price_id: paid_subscription['plan']['id'],
      quantity: paid_subscription['quantity'],
      paid_through: subscriptions.filter_map { |subscription| subscription_period_end(subscription) }.max,
      key: paid_subscription.id
    }

    sync_stripe_customer_location
    new_subscription = replace_subscriptions(subscriptions, change)

    persist_currency(build_custom_attributes(new_subscription, plan))
    Enterprise::Billing::ReconcilePlanFeaturesService.new(account: account).perform
  end

  def resolve_new_price_id(plan)
    target_prices = Enterprise::Billing::PlanConfiguration.price_ids_by_currency(plan)[target_currency]
    raise Error, I18n.t('errors.billing.currency_not_available_for_plan') if target_prices.blank?

    target_prices.first
  end

  def current_plan(subscription)
    plan, = Enterprise::Billing::PlanConfiguration.find_plan_by_price_id(subscription['plan']['id'])
    plan || Enterprise::Billing::PlanConfiguration.find_plan_by_product_id(subscription['plan']['product'])
  end

  # Cancel all current subscriptions (tagged so the deleted-webhook leaves them
  # alone) and create the new-currency subscription. On failure, restore the
  # original paid plan/currency so the account is never left without one.
  #
  # Stripe constraints (verified in test mode):
  # - prorate:false — currencies can't combine on one customer; a proration
  #   item in the old currency would block the new sub.
  # - trial_end = current paid-through date — preserves already-paid time (no
  #   money lost) and makes switching back and forth before the next cycle free
  #   (each switch just re-creates the sub trialing until the same date).
  def replace_subscriptions(subscriptions, change)
    cancel_subscriptions(subscriptions)

    begin
      create_currency_subscription(change[:new_price_id], change, 'switch')
    rescue Stripe::StripeError => e
      create_currency_subscription(change[:original_price_id], change, 'switch-revert')
      raise Error, e.message
    end
  end

  def cancel_subscriptions(subscriptions)
    subscriptions.each do |subscription|
      Stripe::Subscription.update(subscription.id, metadata: { SWITCH_METADATA_KEY => 'true' })
      Stripe::Subscription.cancel(subscription.id, { prorate: false })
    end
  end

  def create_currency_subscription(price_id, change, key_prefix)
    params = { customer: stripe_customer_id, items: [{ price: price_id, quantity: change[:quantity] }] }
    params[:trial_end] = change[:paid_through] if change[:paid_through].present? && change[:paid_through] > Time.current.to_i
    Stripe::Subscription.create(params, { idempotency_key: "#{key_prefix}-#{account.id}-#{change[:key]}" })
  end

  def build_custom_attributes(subscription, plan)
    account.custom_attributes.merge(
      'billing_currency' => target_currency,
      'stripe_price_id' => subscription['plan']['id'],
      'stripe_product_id' => subscription['plan']['product'],
      'plan_name' => plan['name'],
      'subscribed_quantity' => subscription['quantity'],
      'subscription_status' => subscription['status'],
      'subscription_ends_on' => subscription_ends_on(subscription)
    )
  end

  def default_price?(subscription)
    Enterprise::Billing::PlanConfiguration.plan_contains_price_id?(
      Enterprise::Billing::PlanConfiguration.default_plan, subscription['plan']['id']
    )
  end

  def persist_currency(custom_attributes)
    account.update!(custom_attributes: custom_attributes)
  end

  def sync_stripe_customer_location
    Stripe::Customer.update(
      stripe_customer_id,
      address: { country: Enterprise::Billing::Currencies.country_for(target_currency) },
      preferred_locales: [Enterprise::Billing::Currencies.preferred_locale_for(target_currency)]
    )
  end

  # Active and trialing subscriptions. A prior currency switch leaves the new
  # sub trialing until the carried-over paid-through date, so trialing must be
  # included to switch again from that state.
  def live_subscriptions
    Stripe::Subscription.list(customer: stripe_customer_id, status: 'all', limit: 100).data
                        .select { |subscription| %w[active trialing past_due].include?(subscription.status) }
  end

  def validate_payment_method!
    customer = Stripe::Customer.retrieve(stripe_customer_id)
    return if customer.invoice_settings.default_payment_method.present? || customer.default_source.present?

    payment_methods = Stripe::PaymentMethod.list(customer: stripe_customer_id, limit: 1)
    raise Error, I18n.t('errors.billing.no_payment_method') if payment_methods.data.empty?

    Stripe::Customer.update(stripe_customer_id, invoice_settings: { default_payment_method: payment_methods.data.first.id })
  end

  def stripe_customer_id
    account.custom_attributes['stripe_customer_id']
  end
end
