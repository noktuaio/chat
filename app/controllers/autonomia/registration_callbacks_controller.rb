# frozen_string_literal: true

class Autonomia::RegistrationCallbacksController < ApplicationController
  skip_before_action :authenticate_user!, raise: false

  def show
    result = Autonomia::RegistrationCheckout::Provisioner.new(params: callback_params).perform

    redirect_to login_page_url(
      email: ERB::Util.url_encode(result.user.email),
      sso_auth_token: result.user.generate_sso_auth_token
    )
  rescue Autonomia::RegistrationCheckout::Provisioner::InvalidCallback => e
    Rails.logger.warn("[Autonomia Registration] #{e.class}: #{e.message}")
    redirect_to login_page_url(error: 'autonomia-registration-invalid')
  rescue StandardError => e
    Rails.logger.error("[Autonomia Registration] #{e.class}: #{e.message}")
    redirect_to login_page_url(error: 'autonomia-registration-error')
  end

  private

  def callback_params
    params.permit(
      :auth_user_id,
      :checkout_order_id,
      :checkout_status,
      :client_id,
      :company_name,
      :email,
      :full_name,
      :identity_organization_id,
      :name,
      :organization_id,
      :organizationId,
      :product,
      :return_to,
      :user_subscription_id,
      :token,
      :invitation_token
    ).to_h
  end

  def login_page_url(error: nil, email: nil, sso_auth_token: nil)
    query = { email: email, sso_auth_token: sso_auth_token }.compact
    query[:error] = error if error.present?
    "#{frontend_url}/app/login?#{query.to_query}"
  end

  def frontend_url
    ENV.fetch('FRONTEND_URL', request.base_url)
  end
end
