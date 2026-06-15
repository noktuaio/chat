# Orchestrates a billing currency switch:
#   eligibility (no mutation) -> resolve target price -> mark pending -> Stripe swap (self-reverting)
#   -> persist local state (last). Each concern lives in its own collaborator so this stays a thin
# coordinator. Any failure aborts before persisting, so Chatwoot is never left ahead of Stripe; the
# rare window where Stripe succeeds but the local persist fails is reconciled by the subscription
# webhook, which also clears the pending marker.
class Enterprise::Billing::SwitchCurrencyService
  include BillingHelper

  class Error < StandardError; end

  # Tags a cancelled sub so the deleted-webhook skips re-subscribing the default plan.
  SWITCH_METADATA_KEY = 'chatwoot_currency_switch'.freeze

  # Records the in-flight target currency so a crash mid-switch is visible; cleared on success or by
  # the subscription webhook once it reconciles the final state from Stripe.
  PENDING_CURRENCY_KEY = 'billing_currency_switch_pending'.freeze

  pattr_initialize [:account!, :currency!]

  def perform
    subscription = eligibility.subscription!
    resolver = Enterprise::Billing::PlanPriceResolver.new(subscription: subscription, target_currency: target_currency)
    change = change_for(subscription, resolver.target_price_id)

    mark_pending
    new_subscription = executor.execute(subscription: subscription, change: change)

    persist_currency(build_custom_attributes(new_subscription, resolver.plan))
    Enterprise::Billing::ReconcilePlanFeaturesService.new(account: account).perform
  rescue Enterprise::Billing::CurrencySwitchEligibility::Error,
         Enterprise::Billing::PlanPriceResolver::Error,
         Enterprise::Billing::StripeCurrencySwitchExecutor::Error => e
    # The Stripe swap self-reverted, so drop the pending marker and surface a single error type.
    clear_pending
    raise Error, e.message
  end

  private

  def eligibility
    @eligibility ||= Enterprise::Billing::CurrencySwitchEligibility.new(account: account, currency: currency)
  end

  def executor
    @executor ||= Enterprise::Billing::StripeCurrencySwitchExecutor.new(account: account, target_currency: target_currency)
  end

  def target_currency
    @target_currency ||= Enterprise::Billing::Currencies.normalize(currency)
  end

  def change_for(subscription, new_price_id)
    {
      new_price_id: new_price_id,
      quantity: subscription['quantity'],
      # Paid plans preserve paid-through (new sub trials until then); the free default plan switches
      # immediately to an active sub, so a default-plan account can switch again any time.
      paid_through: Enterprise::Billing::PlanConfiguration.default_price?(subscription['plan']['id']) ? nil : subscription_period_end(subscription),
      key: subscription.id
    }
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

  def mark_pending
    account.update!(custom_attributes: account.custom_attributes.merge(PENDING_CURRENCY_KEY => target_currency))
  end

  def clear_pending
    account.update!(custom_attributes: account.custom_attributes.except(PENDING_CURRENCY_KEY))
  end

  def persist_currency(custom_attributes)
    account.update!(custom_attributes: custom_attributes.except(PENDING_CURRENCY_KEY))
  end
end
