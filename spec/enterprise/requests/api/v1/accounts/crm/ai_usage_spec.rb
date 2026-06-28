require 'rails_helper'

# Enterprise overlay of Crm::ReportPolicy gates custom-role agents by the
# `crm_view_reports` permission (OSS allows any account_user). Stripped from the
# FOSS CI run; validated in EE mode.
RSpec.describe 'CRM AI usage API (Enterprise report policy)', type: :request do
  around do |example|
    previous_crm = ENV.fetch('CRM_KANBAN_ENABLED', nil)
    previous_ai = ENV.fetch('CRM_AI_ENABLED', nil)
    ENV['CRM_KANBAN_ENABLED'] = 'true'
    ENV['CRM_AI_ENABLED'] = 'true'
    example.run
  ensure
    previous_crm.nil? ? ENV.delete('CRM_KANBAN_ENABLED') : ENV['CRM_KANBAN_ENABLED'] = previous_crm
    previous_ai.nil? ? ENV.delete('CRM_AI_ENABLED') : ENV['CRM_AI_ENABLED'] = previous_ai
  end

  before { allow(Crm::Ai::ExchangeRate).to receive(:current).and_return(rate: BigDecimal('5.00'), rate_unavailable: false) }

  def custom_role_agent(account:, permissions:)
    role = create(:custom_role, account: account, permissions: permissions)
    agent = create(:user)
    create(:account_user, account: account, user: agent, role: :agent, custom_role: role)
    agent
  end

  it 'denies custom-role agents without crm_view_reports' do
    account, = create_account_and_user
    agent = custom_role_agent(account: account, permissions: ['crm_view'])

    get "/api/v1/accounts/#{account.id}/crm/ai_usage", headers: auth_headers(agent)

    expect(response).to have_http_status(:unauthorized)
  end

  it 'allows custom-role agents with crm_view_reports' do
    account, = create_account_and_user
    agent = custom_role_agent(account: account, permissions: ['crm_view_reports'])

    get "/api/v1/accounts/#{account.id}/crm/ai_usage", headers: auth_headers(agent)

    expect(response).to have_http_status(:ok)
  end
end
