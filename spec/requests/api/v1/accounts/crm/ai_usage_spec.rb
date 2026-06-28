require 'rails_helper'

RSpec.describe 'CRM AI usage API', type: :request do
  around do |example|
    previous_crm = ENV.fetch('CRM_KANBAN_ENABLED', nil)
    previous_ai = ENV.fetch('CRM_AI_ENABLED', nil)
    ENV['CRM_KANBAN_ENABLED'] = 'true'
    ENV['CRM_AI_ENABLED'] = 'true'
    travel_to(Time.zone.parse('2026-06-28 12:00:00')) { example.run }
  ensure
    previous_crm.nil? ? ENV.delete('CRM_KANBAN_ENABLED') : ENV['CRM_KANBAN_ENABLED'] = previous_crm
    previous_ai.nil? ? ENV.delete('CRM_AI_ENABLED') : ENV['CRM_AI_ENABLED'] = previous_ai
  end

  before do
    allow(Crm::Ai::ExchangeRate).to receive(:current).and_return(rate: BigDecimal('5.00'), fetched_at: Time.current.iso8601,
                                                                 rate_unavailable: false)
    allow(Crm::Ai::UsageBroadcaster).to receive(:broadcast)
  end

  it 'returns the raw builder payload wrapped in payload for administrators' do
    account, admin = create_account_and_user
    create(:crm_ai_usage_event, account: account, feature: 'email', model: 'gpt-5.4-mini', cost_estimate: 0.01)

    get "/api/v1/accounts/#{account.id}/crm/ai_usage", headers: auth_headers(admin)

    expect(response).to have_http_status(:ok)
    payload = response.parsed_body['payload']
    expect(payload.dig('totals', 'usage_count')).to eq(1)
    expect(payload.dig('spend_by_resource', 0, 'resource')).to eq('Criação de e-mail')
    expect(response.body).not_to include('gpt-5.4-mini')
    expect(response.body).not_to include('model')
  end

  it 'allows plain agents to view the report' do
    account, = create_account_and_user
    agent, = create_crm_agent(account: account)

    get "/api/v1/accounts/#{account.id}/crm/ai_usage", headers: auth_headers(agent)

    expect(response).to have_http_status(:ok)
  end

  it 'returns 404 when CRM AI is disabled' do
    account, admin = create_account_and_user
    ENV['CRM_AI_ENABLED'] = 'false'

    get "/api/v1/accounts/#{account.id}/crm/ai_usage", headers: auth_headers(admin)

    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body['error']).to eq('crm.ai.disabled')
  end

  it 'exports CSV without content or model columns', :aggregate_failures do
    account, admin = create_account_and_user
    create(:crm_ai_usage_event, account: account, feature: 'copilot', model: 'gpt-5.4', input_tokens: 10, output_tokens: 5,
                                cost_estimate: 0.02)

    get "/api/v1/accounts/#{account.id}/crm/ai_usage/export",
        params: { export_format: 'csv' },
        headers: auth_headers(admin)

    expect(response).to have_http_status(:ok)
    expect(response.headers['Content-Disposition']).to include('attachment')
    expect(response.body.lines.first).to eq("Quando,Recurso,Conta,Tokens,Custo USD,Custo BRL\n")
    expect(response.body).to include('Assistente de respostas')
    expect(response.body).not_to include('model')
    expect(response.body).not_to include('gpt-5.4')
    expect(response.body).not_to include('prompt')
    expect(response.body).not_to include('response')
  end

  it 'neutralizes CSV formula injection in text cells' do
    account, admin = create_account_and_user
    account.update!(name: '=cmd()')
    create(:crm_ai_usage_event, account: account, feature: 'copilot', model: 'gpt-5.4', cost_estimate: 0.02)

    get "/api/v1/accounts/#{account.id}/crm/ai_usage/export",
        params: { export_format: 'csv' },
        headers: auth_headers(admin)

    row = CSV.parse(response.body, headers: true).first

    expect(response).to have_http_status(:ok)
    expect(row['Conta']).to eq("'=cmd()")
  end

  it 'exports JSON without model or content fields' do
    account, admin = create_account_and_user
    create(:crm_ai_usage_event, account: account, feature: 'kb_revisao', model: 'gpt-5.4', cost_estimate: 0.02)

    get "/api/v1/accounts/#{account.id}/crm/ai_usage/export",
        params: { export_format: 'json' },
        headers: auth_headers(admin)

    expect(response).to have_http_status(:ok)
    expect(response.headers['Content-Disposition']).to include('attachment')
    body = response.parsed_body
    expect(body.dig('history', 'rows', 0, 'resource')).to eq('Base de conhecimento')
    expect(response.body).not_to include('model')
    expect(response.body).not_to include('gpt-5.4')
    expect(response.body).not_to include('prompt')
    expect(response.body).not_to include('response')
  end

  it 'allows CRM integration tokens with crm_view_reports to access ai usage when available' do
    skip 'Crm::IntegrationToken is EE-only in this fork' unless defined?(Crm::IntegrationToken)

    account, admin = create_account_and_user
    token = Crm::IntegrationToken.create!(account: account, created_by: admin, name: 'n8n', scopes: ['crm_view_reports'])

    get "/api/v1/accounts/#{account.id}/crm/ai_usage", headers: { api_access_token: token.access_token.token }

    expect(response).to have_http_status(:ok)
  end
end
