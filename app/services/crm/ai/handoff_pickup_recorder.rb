# PR2 — telemetria de tempo-de-pega do convite R3. Quando um humano assume a
# conversa, se havia um convite PENDENTE (invited_at gravado pelo HandoffInviter,
# sem picked_up_at), registra o tempo de pega: relógio de parede e — quando o
# agente tem agenda — segundos ÚTEIS via Sla::BusinessTimeCalculator.
#
# Recebe SNAPSHOT do evento (assignee_id + picked_up_at do momento da atribuição),
# não o estado atual: a fila pode atrasar e a conversa pode ser reatribuída antes
# do job rodar — medir "agora" inflaria o tempo e creditaria o agente errado.
#
# Métrica CRM própria (card.metadata + Crm::Activity 'ai_handoff_pickup'); ZERO
# acoplamento com applied_sla/sla_policy. Idempotente sob concorrência via with_lock.
class Crm::Ai::HandoffPickupRecorder
  def initialize(conversation:, assignee_id:, picked_up_at_iso:)
    @conversation = conversation
    @assignee_id = assignee_id
    @picked_up_at = parse_time(picked_up_at_iso)
  end

  def perform
    return if @assignee_id.blank? || @picked_up_at.blank?

    invited_cards.each { |card| record_pickup(card) }
  end

  private

  # Pré-filtro barato: cards cuja conversa primária é esta e que tiveram convite R3
  # (invited_at). NÃO exclui os já pegos — o earliest-wins mora no recheck sob lock
  # (senão um snapshot posterior que gravasse primeiro barraria o anterior aqui).
  # r2_direct/atribuição manual normal não gravam invited_at → excluídos.
  def invited_cards
    Crm::Card.where(conversation_id: @conversation.id).select do |card|
      card_handoff(card)['invited_at'].present?
    end
  end

  def card_handoff(card)
    (card.metadata || {}).dig('ai', 'handoff') || {}
  end

  # with_lock (FOR UPDATE) + recheck sob lock. Mantém a pega MAIS ANTIGA (a real):
  # sob corrida assign A@t1 / reassign B@t2, a ordem de drenagem da fila não decide
  # quem vence — o snapshot posterior é ignorado. Activity é logada só na 1ª
  # gravação (metadata é a fonte de verdade da métrica), evitando duplicidade.
  def record_pickup(card)
    card.with_lock do
      handoff = card_handoff(card)
      invited_at = parse_time(handoff['invited_at'])
      next if invited_at.blank?

      existing = parse_time(handoff['picked_up_at'])
      next if existing.present? && existing <= @picked_up_at

      wall = (@picked_up_at - invited_at).round
      business = business_seconds(invited_at, @picked_up_at)

      stamp!(card, handoff, wall, business)
      log!(card, wall, business) if existing.blank?
    end
  end

  # Segundos úteis dentro da agenda do AGENTE que pegou (owner=User). Sem agenda
  # usável → nil (fica só o relógio de parede). BusinessTimeCalculator é overlay
  # enterprise, sempre carregado nesta fork; guarda defined? por segurança.
  def business_seconds(from, to)
    schedule = agent_schedule
    return unless schedule&.usable?
    return unless defined?(Sla::BusinessTimeCalculator)

    Sla::BusinessTimeCalculator.new(schedule: schedule).elapsed_seconds(from, to)
  end

  def agent_schedule
    Crm::ServiceSchedule.find_by(
      account_id: @conversation.account_id,
      owner_type: 'User',
      owner_id: @assignee_id
    )
  end

  def stamp!(card, handoff, wall, business)
    metadata = (card.metadata || {}).deep_dup
    merged = handoff.merge(
      'picked_up_at' => @picked_up_at.iso8601,
      'picked_up_by' => @assignee_id,
      'pickup_seconds' => wall,
      'business_pickup_seconds' => business
    )
    metadata['ai'] = (metadata['ai'] || {}).merge('handoff' => merged)
    card.update!(metadata: metadata)
  end

  def log!(card, wall, business)
    Crm::ActivityLogger.new(
      card: card,
      actor: nil,
      event_type: 'ai_handoff_pickup',
      conversation: @conversation,
      payload: {
        assignee_id: @assignee_id,
        pickup_seconds: wall,
        business_pickup_seconds: business
      }
    ).perform
  end

  def parse_time(value)
    Time.zone.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end
end
