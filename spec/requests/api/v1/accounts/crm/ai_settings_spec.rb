require 'rails_helper'

RSpec.describe 'CRM AI settings API', type: :request do
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

  it 'returns 404 when CRM AI is disabled' do
    account, admin = create_account_and_user
    pipeline, = create_crm_pipeline(account: account, user: admin)
    ENV['CRM_AI_ENABLED'] = 'false'

    get "/api/v1/accounts/#{account.id}/crm/pipelines/#{pipeline.id}/ai_settings",
        headers: auth_headers(admin)

    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body['error']).to eq('crm.ai.disabled')
  end

  it 'lets administrators read and update pipeline AI settings' do
    account, admin = create_account_and_user
    pipeline, stage = create_crm_pipeline(account: account, user: admin)

    get "/api/v1/accounts/#{account.id}/crm/pipelines/#{pipeline.id}/ai_settings",
        headers: auth_headers(admin)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'enabled')).to eq(true)

    patch "/api/v1/accounts/#{account.id}/crm/pipelines/#{pipeline.id}/ai_settings",
          params: {
            ai_settings: {
              enabled: true,
              auto_move_enabled: true,
              stale_hours: 24
            },
            stage_criteria: {
              stage.id.to_s => 'Critério de teste'
            }
          },
          headers: auth_headers(admin)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'auto_move_enabled')).to eq(true)
    expect(stage.reload.metadata['ai_criteria']).to eq('Critério de teste')
  end

  it 'persists and returns the new handoff pool + escalation fields', :aggregate_failures do
    account, admin = create_account_and_user
    pipeline, = create_crm_pipeline(account: account, user: admin)
    supervisor, = create_crm_agent(account: account, name: 'Supervisor')

    patch "/api/v1/accounts/#{account.id}/crm/pipelines/#{pipeline.id}/ai_settings",
          params: {
            ai_settings: {
              handoff: {
                enabled: true,
                handoff_mode: 'r3_invite',
                pool_type: 'user',
                pool_id: supervisor.id,
                escalation_action: 'escalate',
                escalation_user_id: supervisor.id,
                pickup_threshold_seconds: 600
              }
            }
          },
          headers: auth_headers(admin)

    expect(response).to have_http_status(:ok)
    handoff = response.parsed_body.dig('payload', 'handoff')
    expect(handoff['pool_type']).to eq('user')
    expect(handoff['pool_id']).to eq(supervisor.id)
    expect(handoff['escalation_action']).to eq('escalate')
    expect(handoff['selector_mode']).to eq(handoff['mode'])

    # partial PATCH (only trigger) must not drop the pool/escalation fields
    patch "/api/v1/accounts/#{account.id}/crm/pipelines/#{pipeline.id}/ai_settings",
          params: { ai_settings: { handoff: { trigger: 'Cliente pediu humano' } } },
          headers: auth_headers(admin)

    expect(response).to have_http_status(:ok)
    handoff = response.parsed_body.dig('payload', 'handoff')
    expect(handoff['trigger']).to eq('Cliente pediu humano')
    expect(handoff['pool_type']).to eq('user')
    expect(handoff['pool_id']).to eq(supervisor.id)
    expect(handoff['escalation_action']).to eq('escalate')
  end

  it 'keeps selector_mode mirroring mode across saves', :aggregate_failures do
    account, admin = create_account_and_user
    pipeline, = create_crm_pipeline(account: account, user: admin)

    patch "/api/v1/accounts/#{account.id}/crm/pipelines/#{pipeline.id}/ai_settings",
          params: { ai_settings: { handoff: { enabled: true, mode: 'direct' } } },
          headers: auth_headers(admin)

    expect(response).to have_http_status(:ok)
    handoff = response.parsed_body.dig('payload', 'handoff')
    expect(handoff['mode']).to eq('direct')
    expect(handoff['selector_mode']).to eq('direct')

    # a partial PATCH of another field must not flip selector_mode to round_robin
    patch "/api/v1/accounts/#{account.id}/crm/pipelines/#{pipeline.id}/ai_settings",
          params: { ai_settings: { handoff: { trigger: 'Atendimento humano' } } },
          headers: auth_headers(admin)

    handoff = response.parsed_body.dig('payload', 'handoff')
    expect(handoff['mode']).to eq('direct')
    expect(handoff['selector_mode']).to eq('direct')
  end
end
