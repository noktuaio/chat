# frozen_string_literal: true

require 'base64'
require 'digest'

class Autonomia::AuthController < ApplicationController
  STATE_PURPOSE = :autonomia_sso_state
  STATE_TTL = 10.minutes

  skip_before_action :authenticate_user!, raise: false

  def start
    return redirect_to login_page_url(error: 'autonomia-sso-disabled') unless sso_enabled?

    verifier = SecureRandom.urlsafe_base64(64)
    state = encode_state(code_verifier: verifier, return_to: permitted_return_to)

    redirect_to authorization_url(state, verifier), allow_other_host: true
  end

  def callback
    return redirect_to login_page_url(error: 'autonomia-sso-error') if params[:error].present?

    state = decode_state
    return redirect_to login_page_url(error: 'autonomia-sso-state') if state.blank?

    client = Autonomia::Sso::Client.new
    token = client.exchange_code!(
      code: params.require(:code),
      redirect_uri: callback_url,
      code_verifier: state[:code_verifier]
    )
    context = client.fetch_context!(token.context_token)
    user = Autonomia::Sso::Provisioner.new(context: context).perform

    redirect_to login_page_url(email: ERB::Util.url_encode(user.email), sso_auth_token: user.generate_sso_auth_token)
  rescue StandardError => e
    Rails.logger.error("[Autonomia SSO] #{e.class}: #{e.message}")
    redirect_to login_page_url(error: 'autonomia-sso-error')
  end

  private

  def authorization_url(state, verifier)
    uri = URI.join(issuer_url, '/login')
    uri.query = {
      client_id: client_id,
      redirect_uri: callback_url,
      response_type: 'code',
      scope: 'openid email profile',
      state: state,
      code_challenge: pkce_challenge(verifier),
      code_challenge_method: 'S256',
      prompt: permitted_prompt,
      return_to: permitted_return_to
    }.compact.to_query
    uri.to_s
  end

  def encode_state(code_verifier:, return_to:)
    encrypted_state = state_encryptor.encrypt_and_sign(
      { code_verifier: code_verifier, return_to: return_to },
      expires_in: STATE_TTL,
      purpose: STATE_PURPOSE
    )
    Base64.urlsafe_encode64(encrypted_state, padding: false)
  end

  def decode_state
    state = state_candidates(params[:state].to_s).filter_map do |candidate|
      state_encryptor.decrypt_and_verify(candidate, purpose: STATE_PURPOSE)
    rescue ActiveSupport::MessageEncryptor::InvalidMessage, ActiveSupport::MessageVerifier::InvalidSignature
      nil
    end.first
    return if state.blank?

    state = state.with_indifferent_access
    return if state[:code_verifier].blank?

    state
  end

  def state_candidates(raw_state)
    [
      decode_urlsafe_state(raw_state),
      raw_state,
      raw_state.tr(' ', '+')
    ].compact.uniq
  end

  def decode_urlsafe_state(raw_state)
    Base64.urlsafe_decode64(raw_state)
  rescue ArgumentError
    nil
  end

  def pkce_challenge(verifier)
    Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
  end

  def state_encryptor
    key_len = ActiveSupport::MessageEncryptor.key_len
    secret = Rails.application.key_generator.generate_key('autonomia-sso-state', key_len)
    ActiveSupport::MessageEncryptor.new(secret, serializer: JSON)
  end

  def callback_url
    ENV.fetch('AUTONOMIA_AUTH_REDIRECT_URI', "#{frontend_url}/auth/autonomia/callback")
  end

  def permitted_return_to
    return nil if params[:return_to].blank?

    value = params[:return_to].to_s
    value.start_with?('/app') ? value : nil
  end

  def permitted_prompt
    params[:prompt].to_s == 'login' ? 'login' : nil
  end

  def login_page_url(error: nil, email: nil, sso_auth_token: nil)
    query = { email: email, sso_auth_token: sso_auth_token }.compact
    query[:error] = error if error.present?
    "#{frontend_url}/app/login?#{query.to_query}"
  end

  def frontend_url
    ENV.fetch('FRONTEND_URL', request.base_url)
  end

  def issuer_url
    ENV.fetch('AUTONOMIA_AUTH_ISSUER', 'https://auth.autonomia.site').delete_suffix('/')
  end

  def client_id
    ENV.fetch('AUTONOMIA_AUTH_CLIENT_ID', 'talkai')
  end

  def sso_enabled?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch('AUTONOMIA_SSO_ENABLED', true))
  end
end
