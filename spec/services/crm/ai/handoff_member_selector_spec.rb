require 'rails_helper'

RSpec.describe Crm::Ai::HandoffMemberSelector do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:agent) { create(:user, account: account) }
  let(:busy_agent) { create(:user, account: account) }
  let(:outsider) { create(:user, account: account) }

  before do
    create(:inbox_member, inbox: inbox, user: agent)
    create(:inbox_member, inbox: inbox, user: busy_agent)
    allow(OnlineStatusTracker).to receive(:get_available_users).with(account.id).and_return({})
  end

  it 'uses the inbox member pool by default and balances round-robin by open conversation count' do
    create(:conversation, account: account, inbox: inbox, assignee: busy_agent)

    selected = described_class.new(inbox: inbox, account_id: account.id).perform

    expect(selected).to eq(agent)
  end

  it 'restricts the eligible pool to a valid user member id' do
    selected = described_class.new(
      inbox: inbox,
      account_id: account.id,
      pool_type: 'user',
      pool_id: busy_agent.id
    ).perform

    expect(selected).to eq(busy_agent)
  end

  it 'falls back to inbox members when user pool id is not an inbox member' do
    selected = described_class.new(
      inbox: inbox,
      account_id: account.id,
      pool_type: 'user',
      pool_id: outsider.id
    ).perform

    expect(selected).to be_present
    expect([agent, busy_agent]).to include(selected)
    expect(selected).not_to eq(outsider)
  end

  it 'respects require_online gating for a single-user pool' do
    selector = described_class.new(
      inbox: inbox,
      account_id: account.id,
      require_online: true,
      pool_type: 'user',
      pool_id: agent.id
    )

    expect(selector.perform).to be_nil
    expect(selector.held_for_online?).to be(true)
  end
end
