class Crm::Ai::HandoffDrainJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform
    return unless Crm::Ai::Config.enabled?

    Crm::Pipeline.active.find_each do |pipeline|
      held_cards(pipeline).find_each { |card| drain(card) if drainable?(card) }
    end
  end

  private

  # Pré-filtro barato no JSONB: o volume esperado é baixo, mas isso evita varrer
  # todo card aberto. A elegibilidade real fica no lock, porque humano/self-assign
  # e outro tick do cron podem mudar conversa/status entre a query e a tentativa.
  def held_cards(pipeline)
    pipeline.cards.open
            .includes(:primary_conversation)
            .where("metadata #>> '{ai,handoff_hold,held_at}' IS NOT NULL")
  end

  # Elegibilidade por CARD (não por pipeline): handoff pode estar ligado só numa
  # etapa. Usa a mesma resolução do executor, onde a etapa vence o padrão do funil.
  def drainable?(card)
    settings = Crm::Ai::Config.handoff_settings(card.stage, card.pipeline)
    settings[:enabled] && settings[:handoff_mode] == 'r2_direct'
  end

  # Drena sem IA: trava a CONVERSA primeiro, na mesma ordem do CardSyncer
  # (conversation→card), para não criar deadlock ABBA. O executor abre transação
  # aninhada e o AssignmentService atualiza a MESMA linha de conversa já travada
  # (reentrante). O recheck de assignee_id sob lock fecha a brecha de self-assign
  # humano entre a query do cron e a tentativa de atribuição.
  def drain(card)
    conversation = card.primary_conversation
    return clear_handoff_hold!(card) if conversation.blank?

    conversation.with_lock do
      next clear_handoff_hold!(card) unless card.reload.open?
      next unless held?(card)
      # Humano assumiu por fora do executor (self-assign) → terminal: limpa o
      # marcador para o card não ser requeriado nem travar a conversa a cada tick.
      next clear_handoff_hold!(card) if conversation.assignee_id.present?

      Crm::Ai::HandoffExecutor.new(card: card, handoff: handoff_payload(card), trigger: 'drain').perform
    end
  end

  def held?(card)
    card.metadata.to_h.dig('ai', 'handoff_hold', 'held_at').present?
  end

  def handoff_payload(card)
    card.metadata.to_h.dig('ai', 'handoff_hold', 'handoff') || {}
  end

  def clear_handoff_hold!(card)
    metadata = (card.metadata || {}).deep_dup
    ai = metadata['ai'] || {}
    return unless ai.key?('handoff_hold')

    metadata['ai'] = ai.except('handoff_hold')
    card.update!(metadata: metadata)
  end
end
