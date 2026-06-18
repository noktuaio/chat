# frozen_string_literal: true

class Autonomia::ProductInvitations::AgentInviter
  class Error < StandardError; end

  Result = Struct.new(:email, :name, :role, :invitation_url, keyword_init: true)

  pattr_initialize [:account!, :inviter!, :agent_params!]

  def perform
    access_token = Autonomia::Sso::TokenStore.access_token_for(inviter)
    user_link = Autonomia::UserLink.find_by(user: inviter)

    raise Error, 'Sua sessao do Auth expirou. Saia e entre novamente para convidar agentes.' if access_token.blank? || user_link.blank?
    raise Error, 'Este usuario ja faz parte da conta.' if account.users.exists?(email: email)

    response = Autonomia::ProductInvitations::Client.new.create!(
      access_token: access_token,
      payload: invitation_payload(user_link)
    )
    store_pending_invitation!(response)
    Result.new(email: email, name: name, role: role, invitation_url: response.dig('invitation', 'invitationUrl') || response['invitationUrl'])
  rescue Autonomia::ProductInvitations::Client::Error => e
    raise Error, e.message
  end

  private

  def invitation_payload(user_link)
    {
      email: email,
      fullName: name,
      clientId: client_id,
      invitedByUserId: user_link.identity_user_id,
      productBaseUrl: product_base_url
    }
  end

  def store_pending_invitation!(response)
    invitations = pending_invitations.merge(
      email => {
        'email' => email,
        'name' => name,
        'role' => role,
        'custom_role_id' => custom_role_id,
        'invited_by_user_id' => inviter.id,
        'auth_invitation_id' => response.dig('invitation', 'id') || response['id'],
        'created_at' => Time.current.iso8601
      }
    )

    account.update!(
      custom_attributes: (account.custom_attributes || {}).merge(
        'autonomia_pending_agent_invitations' => invitations
      )
    )
  end

  def pending_invitations
    (account.custom_attributes || {}).fetch('autonomia_pending_agent_invitations', {})
  end

  def email
    @email ||= agent_params.fetch('email').to_s.downcase
  end

  def name
    agent_params['name'].presence || email.split('@').first
  end

  def role
    value = agent_params['role'].presence || 'agent'
    AccountUser.roles.key?(value) ? value : 'agent'
  end

  def custom_role_id
    agent_params['custom_role_id'].presence
  end

  def client_id
    ENV.fetch('AUTONOMIA_AUTH_CLIENT_ID', 'talkai')
  end

  def product_base_url
    ENV.fetch('FRONTEND_URL', 'https://agents.autonomia.site')
  end
end
