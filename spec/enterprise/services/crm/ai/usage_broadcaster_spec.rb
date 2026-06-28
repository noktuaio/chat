require 'rails_helper'

# Enterprise overlay: broadcast recipients are filtered by the granular
# crm_view_reports permission for custom-role agents. Stripped from FOSS CI;
# validated in EE mode.
RSpec.describe Crm::Ai::UsageBroadcaster do
  before do
    broadcast_calls
    allow(ActionCable.server).to receive(:broadcast) do |stream, message|
      broadcast_calls << [stream, message]
    end
  end

  it 'excludes custom-role agents without crm_view_reports', :aggregate_failures do
    account, admin = create_account_and_user
    allowed_role = create(:custom_role, account: account, permissions: ['crm_view_reports'])
    denied_role = create(:custom_role, account: account, permissions: ['crm_view'])
    allowed_custom = create(:user)
    denied_custom = create(:user)
    create(:account_user, account: account, user: allowed_custom, role: :agent, custom_role: allowed_role)
    create(:account_user, account: account, user: denied_custom, role: :agent, custom_role: denied_role)
    event = build(:crm_ai_usage_event, account: account, feature: 'agente_resposta', model: 'gpt-5.4')

    described_class.broadcast(event)

    streams = broadcast_calls.map(&:first)
    expect(streams).to include(admin.pubsub_token, allowed_custom.pubsub_token)
    expect(streams).not_to include(denied_custom.pubsub_token)
    expect(streams).not_to include("account_#{account.id}")
  end

  def broadcast_calls
    @broadcast_calls ||= []
  end
end
