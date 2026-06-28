class Crm::Ai::UsageBroadcastJob < ApplicationJob
  queue_as :low

  def perform(event_id)
    event = Crm::AiUsageEvent.find_by(id: event_id)
    return if event.blank?

    Crm::Ai::UsageBroadcaster.broadcast(event)
  end
end
