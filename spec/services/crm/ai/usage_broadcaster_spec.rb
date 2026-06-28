require 'rails_helper'

RSpec.describe Crm::Ai::UsageBroadcaster do
  before do
    broadcast_calls
    allow(ActionCable.server).to receive(:broadcast) do |stream, message|
      broadcast_calls << [stream, message]
    end
  end

  # OSS Crm::ReportPolicy#view? allows any account_user (admins + agents). The
  # custom-role granular gating (crm_view_reports) is Enterprise-only and is
  # covered in spec/enterprise. Here we assert the mode-agnostic guarantees:
  # per-user delivery to report-viewers and NEVER the account-wide stream.
  it 'broadcasts per authorized user and never to the account stream', :aggregate_failures do
    account, admin = create_account_and_user
    plain_agent, = create_crm_agent(account: account)
    event = build(:crm_ai_usage_event, account: account, feature: 'agente_resposta', model: 'gpt-5.4')

    described_class.broadcast(event)

    streams = broadcast_calls.map(&:first)
    expect(streams).to contain_exactly(admin.pubsub_token, plain_agent.pubsub_token)
    expect(streams).not_to include("account_#{account.id}")
    broadcast_calls.each do |(_, message)|
      expect(message[:event]).to eq('crm.ai_usage.created')
      expect(message[:data]).to include(
        account_id: account.id,
        resource: 'Assistente de respostas',
        input_tokens: event.input_tokens,
        cached_tokens: event.cached_tokens,
        output_tokens: event.output_tokens,
        total_tokens: event.input_tokens + event.output_tokens,
        cost_usd: event.cost_estimate.to_f,
        created_at: event.created_at.iso8601
      )
      expect(message.to_json).not_to include('model')
      expect(message.to_json).not_to include('prompt')
      expect(message.to_json).not_to include('response')
    end
  end

  def broadcast_calls
    @broadcast_calls ||= []
  end
end
