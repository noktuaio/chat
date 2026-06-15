# Ensures the customer's default Stripe payment method can actually bill the given currency. PIX/boleto
# are BRL-only, so when an account moves to a currency they can't pay we drop them as the default and
# pick a compatible method (a card) if one is attached. Incompatible methods stay attached for later.
class Enterprise::Billing::DefaultPaymentMethodReconciler
  pattr_initialize [:account!, :currency!]

  # Returns the id of a currency-compatible default payment method, or nil if none is available.
  def reconcile
    customer = Stripe::Customer.retrieve(stripe_customer_id)
    # Legacy card sources are currency-agnostic.
    return customer.default_source if customer.default_source.present?

    current_default = customer.invoice_settings.default_payment_method
    return current_default if compatible?(payment_methods.find { |method| method.id == current_default })

    compatible = payment_methods.find { |method| compatible?(method) }
    return make_default(compatible.id) if compatible

    unset_default if current_default.present?
    nil
  end

  private

  def payment_methods
    @payment_methods ||= Stripe::PaymentMethod.list(customer: stripe_customer_id, limit: 100).data
  end

  def compatible?(payment_method)
    payment_method.present? && Enterprise::Billing::Currencies.payment_method_supports?(payment_method.type, currency)
  end

  def make_default(payment_method_id)
    Stripe::Customer.update(stripe_customer_id, invoice_settings: { default_payment_method: payment_method_id })
    payment_method_id
  end

  def unset_default
    Stripe::Customer.update(stripe_customer_id, invoice_settings: { default_payment_method: '' })
  end

  def stripe_customer_id
    account.custom_attributes['stripe_customer_id']
  end
end
