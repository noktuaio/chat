class Enterprise::Billing::SwitchCurrencyService
  include BillingHelper

  class Error < StandardError; end

  # Tags a cancelled sub so the deleted-webhook skips re-subscribing the default plan.
  SWITCH_METADATA_KEY = 'chatwoot_currency_switch'.freeze

  # Stripe statuses that are done and can't reactivate — ignored when checking switch eligibility.
  TERMINAL_STATUSES = %w[canceled incomplete_expired].freeze

  pattr_initialize [:account!, :currency!]

  # Only the simple happy path is allowed: exactly one active paid subscription, nothing else pending.
  # Everything else is rejected up front (validated), so we never mutate Stripe for an edge case.
  # Order: validate (no mutation) -> idempotent customer sync -> subscription replacement (self-reverting)
  # -> local DB persist (last, alone), so any failure aborts cleanly without leaving split state.
  def perform
    validate!
    subscription = eligible_paid_subscription!
    plan = resolve_plan!(subscription)
    change = change_for(subscription, plan)

    validate_payment_method!
    sync_stripe_customer_location

    new_subscription = replace_subscription(subscription, change)
    persist_currency(build_custom_attributes(new_subscription, plan))
    Enterprise::Billing::ReconcilePlanFeaturesService.new(account: account).perform
  end

  private

  def target_currency
    @target_currency ||= Enterprise::Billing::Currencies.normalize(currency)
  end

  def validate!
    raise Error, I18n.t('errors.billing.currency_switch_unavailable') unless Enterprise::Billing::Currencies.rollout_enabled?(account.locale)
    raise Error, I18n.t('errors.billing.unsupported_currency') unless Enterprise::Billing::Currencies.supported?(currency)
    raise Error, I18n.t('errors.billing.same_currency') if target_currency == account.billing_currency
    raise Error, I18n.t('errors.billing.stripe_customer_not_configured') if stripe_customer_id.blank?
  end

  # Exactly one live subscription, active, on a paid plan. Anything else (pending, extra, or free) is rejected.
  def eligible_paid_subscription!
    subscription = live_subscriptions.first
    eligible = live_subscriptions.one? && subscription.status == 'active' && !default_price?(subscription)
    raise Error, I18n.t('errors.billing.switch_requires_active_subscription') unless eligible

    subscription
  end

  def resolve_plan!(subscription)
    plan = current_plan(subscription)
    raise Error, I18n.t('errors.billing.unknown_plan') if plan.blank?

    plan
  end

  def change_for(subscription, plan)
    {
      new_price_id: resolve_new_price_id(plan),
      original_price_id: subscription['plan']['id'],
      quantity: subscription['quantity'],
      paid_through: subscription_period_end(subscription),
      key: subscription.id
    }
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

  # Cancel the old sub, create the new-currency sub; revert to the original plan on failure.
  # prorate:false (Stripe can't mix currencies); trial_end keeps the already-paid time.
  def replace_subscription(subscription, change)
    cancel_subscription(subscription)

    begin
      create_currency_subscription(change[:new_price_id], change, 'switch')
    rescue Stripe::StripeError => e
      create_currency_subscription(change[:original_price_id], change, 'switch-revert')
      raise Error, e.message
    end
  end

  def cancel_subscription(subscription)
    Stripe::Subscription.update(subscription.id, metadata: { SWITCH_METADATA_KEY => 'true' })
    Stripe::Subscription.cancel(subscription.id, { prorate: false })
  rescue Stripe::StripeError
    # Clear the flag so a still-live sub isn't permanently skipped by the webhook guard.
    Stripe::Subscription.update(subscription.id, metadata: { SWITCH_METADATA_KEY => '' })
    raise
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

  def all_subscriptions
    @all_subscriptions ||= Stripe::Subscription.list(customer: stripe_customer_id, status: 'all', limit: 100).data
  end

  def live_subscriptions
    @live_subscriptions ||= all_subscriptions.reject { |subscription| TERMINAL_STATUSES.include?(subscription.status) }
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
