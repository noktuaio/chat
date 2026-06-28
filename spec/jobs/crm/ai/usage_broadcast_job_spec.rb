require 'rails_helper'

RSpec.describe Crm::Ai::UsageBroadcastJob, type: :job do
  it 'broadcasts the usage event when the enqueued job runs' do
    event = create(:crm_ai_usage_event)
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    allow(Crm::Ai::UsageBroadcaster).to receive(:broadcast)

    perform_enqueued_jobs(only: described_class) do
      described_class.perform_later(event.id)
    end

    expect(Crm::Ai::UsageBroadcaster).to have_received(:broadcast).with(event)
  end

  it 'does nothing when the event no longer exists' do
    allow(Crm::Ai::UsageBroadcaster).to receive(:broadcast)

    described_class.perform_now(-1)

    expect(Crm::Ai::UsageBroadcaster).not_to have_received(:broadcast)
  end
end
