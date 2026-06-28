require 'rails_helper'

RSpec.describe Crm::AiUsageEvent, type: :model do
  it 'registers usage broadcasting as an after create commit callback' do
    callback = described_class._commit_callbacks.find { |item| item.filter == :broadcast_usage_created }

    expect(callback).to be_present
    expect(callback.kind).to eq(:after)
    expect(callback.instance_variable_get(:@name)).to eq(:commit)
    expect(callback.instance_variable_get(:@if)).to be_present
  end

  it 'enqueues the post-commit broadcast job' do
    event = build_stubbed(:crm_ai_usage_event)

    expect do
      event.send(:broadcast_usage_created)
    end.to have_enqueued_job(Crm::Ai::UsageBroadcastJob).with(event.id).on_queue('low')
  end
end
