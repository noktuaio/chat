# Enfileirado pelo ConversationObserverListener#assignee_changed. Registra a pega
# de um convite R3 (tempo convite→pega) quando um humano assume a conversa.
# Auto-gated no recorder: sem convite pendente → no-op barato.
class Crm::Ai::HandoffPickupJob < ApplicationJob
  queue_as :default

  def perform(conversation_id, assignee_id, picked_up_at_iso)
    conversation = Conversation.find_by(id: conversation_id)
    return if conversation.blank?

    Crm::Ai::HandoffPickupRecorder.new(
      conversation: conversation,
      assignee_id: assignee_id,
      picked_up_at_iso: picked_up_at_iso
    ).perform
  end
end
