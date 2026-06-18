# frozen_string_literal: true

class Autonomia::Sso::Provisioner
  pattr_initialize [:context!, { token: nil }]

  def perform
    ActiveRecord::Base.transaction do
      user = find_or_create_user
      account = find_or_create_account
      sync_account_name(account)
      link_user(user)
      link_account(account)
      ensure_account_user(user, account)
      user
    end
  end

  private

  def find_or_create_user
    linked_user || User.from_email(identity_email) || create_user
  end

  def find_or_create_account
    Autonomia::AccountLink.find_by(identity_organization_id: identity_organization_id)&.account || create_account
  end

  def create_user
    user = User.new(
      email: identity_email,
      name: identity_name.presence || identity_email,
      password: random_password,
      password_confirmation: random_password
    )
    user.skip_confirmation!
    user.save!
    user
  end

  def create_account
    Account.create!(
      name: organization_name.presence || identity_email.split('@').last,
      locale: I18n.locale,
      custom_attributes: { 'onboarding_step' => 'account_details' }
    )
  end

  def sync_account_name(account)
    return if organization_name.blank?
    return if account.name == organization_name

    account.update!(name: organization_name)
  end

  def link_user(user)
    Autonomia::UserLink.find_or_initialize_by(identity_user_id: identity_user_id).tap do |link|
      link.user = user
      link.email = identity_email
      link.metadata = (link.metadata || {}).merge('identity_user' => identity_user)
      link.save!
      Autonomia::Sso::TokenStore.write!(link, token) if token.present?
    end
  end

  def link_account(account)
    Autonomia::AccountLink.find_or_initialize_by(identity_organization_id: identity_organization_id).tap do |link|
      link.account = account
      link.metadata = { 'identity_organization' => identity_organization }
      link.save!
    end
  end

  def ensure_account_user(user, account)
    AccountUser.find_or_initialize_by(user: user, account: account).tap do |account_user|
      pending_invitation = pending_agent_invitation(account)
      account_user.role = pending_invitation&.fetch('role', nil).presence || 'administrator'
      account_user.custom_role_id = pending_invitation['custom_role_id'] if pending_invitation&.fetch('custom_role_id', nil).present?
      account_user.inviter_id ||= pending_invitation['invited_by_user_id'] if pending_invitation.present?
      account_user.save!
      consume_pending_agent_invitation(account) if pending_invitation.present?
    end
  end

  def pending_agent_invitation(account)
    pending_agent_invitations(account)[identity_email.downcase]
  end

  def consume_pending_agent_invitation(account)
    invitations = pending_agent_invitations(account)
    invitations.delete(identity_email.downcase)
    account.update!(
      custom_attributes: (account.custom_attributes || {}).merge(
        'autonomia_pending_agent_invitations' => invitations
      )
    )
  end

  def pending_agent_invitations(account)
    (account.custom_attributes || {}).fetch('autonomia_pending_agent_invitations', {})
  end

  def linked_user
    Autonomia::UserLink.find_by(identity_user_id: identity_user_id)&.user
  end

  def identity_user
    context['user'] || {}
  end

  def identity_organization
    context['activeOrganization'] || context['active_organization'] || Array(context['organizations']).first || {}
  end

  def identity_user_id
    identity_user['id'] || identity_user['sub'] || identity_user['cognitoSub'] || identity_user['cognito_sub'] || identity_email
  end

  def identity_email
    identity_user.fetch('email')
  end

  def identity_name
    identity_user['name'] || identity_user['displayName'] || identity_user['display_name']
  end

  def identity_organization_id
    identity_organization['id'] || identity_organization['organizationId'] || identity_organization['organization_id'] || identity_email
  end

  def organization_name
    identity_organization['name'] || identity_organization['displayName'] || identity_organization['display_name']
  end

  def random_password
    @random_password ||= "#{SecureRandom.hex(24)}aA1!"
  end
end
