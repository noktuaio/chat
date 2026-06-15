# Resolves the current plan and the target-currency price id for a currency switch.
class Enterprise::Billing::PlanPriceResolver
  class Error < StandardError; end

  pattr_initialize [:subscription!, :target_currency!]

  def plan
    @plan ||= resolve_plan
  end

  def target_price_id
    by_currency = Enterprise::Billing::PlanConfiguration.price_ids_by_currency(plan)
    target_prices = by_currency[target_currency]
    raise Error, I18n.t('errors.billing.currency_not_available_for_plan') if target_prices.blank?

    # Map by the current price's position within its own currency, so monthly->monthly / annual->annual
    # instead of always landing on the first configured price (which could change the customer's cadence).
    source_prices = by_currency.values.find { |ids| ids.include?(current_price_id) } || []
    index = source_prices.index(current_price_id) || 0
    target_prices[index] || target_prices.first
  end

  private

  def current_price_id
    subscription['plan']['id']
  end

  def resolve_plan
    plan, = Enterprise::Billing::PlanConfiguration.find_plan_by_price_id(current_price_id)
    plan ||= Enterprise::Billing::PlanConfiguration.find_plan_by_product_id(subscription['plan']['product'])
    raise Error, I18n.t('errors.billing.unknown_plan') if plan.blank?

    plan
  end
end
