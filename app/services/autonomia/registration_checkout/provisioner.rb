# frozen_string_literal: true

class Autonomia::RegistrationCheckout::Provisioner
  class InvalidCallback < StandardError; end

  ACCEPTED_STATUSES = %w[provisioned active completed paid success trialing].freeze

  Result = Struct.new(:user, :account, keyword_init: true)

  pattr_initialize [:params!]

  def perform
    validate!

    ActiveRecord::Base.transaction do
      user = find_or_create_user
      account = find_or_create_account
      link_user(user)
      link_account(account)
      ensure_admin_membership(user, account)

      Result.new(user: user, account: account)
    end
  end

  private

  def validate!
    raise InvalidCallback, 'Invitation callbacks must use the invitation flow.' if invitation_callback?
    raise InvalidCallback, 'Checkout was not completed.' unless checkout_completed?
    raise InvalidCallback, 'Missing auth_user_id.' if auth_user_id.blank?
    raise InvalidCallback, 'Missing email.' if email.blank?
    raise InvalidCallback, 'Missing client_id.' if client_id.blank?
    raise InvalidCallback, 'Pending invitations must use the invitation flow.' if pending_agent_invitation?
  end

  def find_or_create_user
    linked_user || User.from_email(email) || create_user
  end

  def find_or_create_account
    linked_account || create_account
  end

  def create_user
    user = User.new(
      email: email,
      name: full_name.presence || email,
      password: random_password,
      password_confirmation: random_password
    )
    user.skip_confirmation!
    user.save!
    user
  end

  def create_account
    Account.create!(
      name: company_name.presence || full_name.presence || email.split('@').last,
      locale: I18n.locale,
      custom_attributes: {
        'onboarding_step' => 'account_details',
        'autonomia_registration_checkout' => checkout_metadata
      }
    )
  end

  def link_user(user)
    Autonomia::UserLink.find_or_initialize_by(identity_user_id: auth_user_id).tap do |link|
      link.user = user
      link.email = email
      link.metadata = (link.metadata || {}).merge(
        'identity_user' => identity_user_metadata,
        'registration_checkout' => checkout_metadata
      )
      link.save!
    end
  end

  def link_account(account)
    Autonomia::AccountLink.find_or_initialize_by(identity_organization_id: organization_id).tap do |link|
      link.account = account
      link.metadata = (link.metadata || {}).merge(
        'identity_organization' => identity_organization_metadata,
        'registration_checkout' => checkout_metadata
      )
      link.save!
    end
  end

  def ensure_admin_membership(user, account)
    AccountUser.find_or_initialize_by(user: user, account: account).tap do |account_user|
      account_user.role = 'administrator'
      account_user.save!
    end
  end

  def linked_user
    Autonomia::UserLink.find_by(identity_user_id: auth_user_id)&.user
  end

  def linked_account
    Autonomia::AccountLink.find_by(identity_organization_id: organization_id)&.account
  end

  def checkout_completed?
    ACCEPTED_STATUSES.include?(checkout_status)
  end

  def invitation_callback?
    callback_params['token'].present? || callback_params['invitation_token'].present?
  end

  def pending_agent_invitation?
    Account.where(
      "custom_attributes -> 'autonomia_pending_agent_invitations' ? :email",
      email: email
    ).exists?
  end

  def checkout_metadata
    {
      'auth_user_id' => auth_user_id,
      'checkout_order_id' => callback_params['checkout_order_id'],
      'checkout_status' => checkout_status,
      'client_id' => client_id,
      'email' => email,
      'product' => callback_params['product'],
      'return_to' => permitted_return_to,
      'source' => 'register_callback',
      'user_subscription_id' => callback_params['user_subscription_id']
    }.compact
  end

  def identity_user_metadata
    {
      'id' => auth_user_id,
      'email' => email,
      'name' => full_name
    }.compact
  end

  def identity_organization_metadata
    {
      'id' => organization_id,
      'name' => company_name,
      'fallback' => organization_id_fallback?
    }.compact
  end

  def organization_id
    @organization_id ||= callback_params['organization_id'].presence ||
                         callback_params['identity_organization_id'].presence ||
                         callback_params['organizationId'].presence ||
                         "registration:#{client_id}:#{auth_user_id}"
  end

  def organization_id_fallback?
    callback_params['organization_id'].blank? &&
      callback_params['identity_organization_id'].blank? &&
      callback_params['organizationId'].blank?
  end

  def auth_user_id
    callback_params['auth_user_id'].presence
  end

  def email
    @email ||= callback_params['email'].to_s.strip.downcase
  end

  def full_name
    callback_params['full_name'].presence || callback_params['name'].presence
  end

  def company_name
    callback_params['company_name'].presence
  end

  def checkout_status
    callback_params['checkout_status'].to_s.strip.downcase
  end

  def client_id
    callback_params['client_id'].presence || ENV.fetch('AUTONOMIA_AUTH_CLIENT_ID', nil)
  end

  def permitted_return_to
    value = callback_params['return_to'].to_s
    value.start_with?('/app') ? value : nil
  end

  def callback_params
    @callback_params ||= params.to_h.with_indifferent_access
  end

  def random_password
    @random_password ||= "#{SecureRandom.hex(24)}aA1!"
  end
end
