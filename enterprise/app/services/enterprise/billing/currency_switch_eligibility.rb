# Validates that an account may switch billing currency and returns the single switchable
# subscription. Performs no Stripe mutations, so a rejected switch never touches billing state.
class Enterprise::Billing::CurrencySwitchEligibility
  class Error < StandardError; end

  # Stripe statuses that are done and can't reactivate — ignored when looking for the live subscription.
  TERMINAL_STATUSES = %w[canceled incomplete_expired].freeze

  # Healthy statuses that may switch currency; trialing covers a sub left trialing by a prior paid switch.
  SWITCHABLE_STATUSES = %w[active trialing].freeze

  pattr_initialize [:account!, :currency!]

  # Returns the one live, switchable subscription (paid or default plan); raises otherwise.
  def subscription!
    validate!
    eligible_subscription!
  end

  private

  def validate!
    raise Error, I18n.t('errors.billing.currency_switch_unavailable') unless account.feature_enabled?('billing_currency_switch')
    raise Error, I18n.t('errors.billing.unsupported_currency') unless Enterprise::Billing::Currencies.supported?(currency)
    raise Error, I18n.t('errors.billing.same_currency') if target_currency == account.billing_currency
    raise Error, I18n.t('errors.billing.stripe_customer_not_configured') if stripe_customer_id.blank?
  end

  # Exactly one live subscription in a switchable state. Anything else (pending or extra) is rejected
  # up front so we never mutate Stripe for an edge case.
  def eligible_subscription!
    subscription = live_subscriptions.first
    eligible = live_subscriptions.one? && SWITCHABLE_STATUSES.include?(subscription&.status)
    raise Error, I18n.t('errors.billing.switch_requires_active_subscription') unless eligible

    subscription
  end

  def target_currency
    @target_currency ||= Enterprise::Billing::Currencies.normalize(currency)
  end

  def stripe_customer_id
    account.custom_attributes['stripe_customer_id']
  end

  def live_subscriptions
    @live_subscriptions ||= Stripe::Subscription.list(customer: stripe_customer_id, status: 'all', limit: 100)
                                                .data.reject { |subscription| TERMINAL_STATUSES.include?(subscription.status) }
  end
end
