class Crm::Ai::HandoffEscalationJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform
    return unless Crm::Ai::Config.enabled?

    Crm::Pipeline.active.find_each do |pipeline|
      candidate_cards(pipeline).find_each do |card|
        settings = Crm::Ai::Config.handoff_settings(card.stage, card.pipeline)
        next unless escalatable?(settings)

        escalate(card, settings)
      end
    end
  end

  private

  def candidate_cards(pipeline)
    pipeline.cards.open
            .includes(:primary_conversation)
            .where("jsonb_typeof(metadata #> '{ai,handoffs}') = 'array'")
            .where("jsonb_array_length(metadata #> '{ai,handoffs}') > 0")
  end

  def escalatable?(settings)
    settings[:enabled] &&
      settings[:handoff_mode] == 'r3_invite' &&
      settings[:escalation_user_id].present? &&
      settings[:pickup_threshold_seconds].to_i.positive?
  end

  def escalate(card, settings)
    conversation = card.primary_conversation
    return if conversation.blank?

    conversation.with_lock { escalate_locked(card, conversation, settings) }
  end

  def escalate_locked(card, conversation, _settings)
    card.reload
    settings = Crm::Ai::Config.handoff_settings(card.stage, card.pipeline)
    return unless card.open? && escalatable?(settings)
    return if conversation.assignee_id.present?

    cycle = breached_open_cycle(card, settings[:pickup_threshold_seconds])
    return if cycle.blank?

    user = escalation_user(card, conversation, settings[:escalation_user_id])
    return if user.blank?

    return unless assign_user(conversation, user)

    conversation.bot_handoff!
    stamp_escalation!(card, cycle, user.id)
    log_activity!(card, conversation, user.id, settings[:pickup_threshold_seconds])
  end

  def breached_open_cycle(card, threshold_seconds)
    cycle = open_cycle(card)
    return if cycle.blank?

    invited_at = parse_time(cycle['invited_at'])
    invited_at.present? && invited_at <= threshold_seconds.to_i.seconds.ago ? cycle : nil
  end

  def assign_user(conversation, user)
    Conversations::AssignmentService.new(conversation: conversation, assignee_id: user.id).perform.present?
  end

  def escalation_user(card, conversation, user_id)
    user = card.account.users.find_by(id: user_id)
    return unless user.present? && inbox_member?(conversation, user)

    user
  end

  def inbox_member?(conversation, user)
    conversation.inbox&.members&.exists?(id: user.id)
  end

  def open_cycle(card)
    cycles = (card.metadata || {}).dig('ai', 'handoffs')
    return unless cycles.is_a?(Array)

    cycles.reverse.find do |cycle|
      cycle['invited_at'].present? &&
        cycle['picked_up_at'].blank? &&
        cycle['canceled_at'].blank? &&
        cycle['escalated_at'].blank?
    end
  end

  def stamp_escalation!(card, cycle, user_id)
    metadata = (card.metadata || {}).deep_dup
    ai = metadata['ai'] || {}
    cycles = ai['handoffs']
    return unless cycles.is_a?(Array)

    fields = {
      'escalated_at' => Time.current.iso8601,
      'escalated_to' => user_id
    }
    updated_cycles, matched = stamp_cycle(cycles, cycle, fields)
    return unless matched

    ai['handoffs'] = updated_cycles
    stamp_pointer!(ai, cycle, fields)
    metadata['ai'] = ai
    card.update!(metadata: metadata)
  end

  def stamp_cycle(cycles, cycle, fields)
    matched = false
    updated = cycles.map do |stored_cycle|
      if !matched && cycle_matches?(stored_cycle, cycle)
        matched = true
        stored_cycle.merge(fields)
      else
        stored_cycle
      end
    end
    [updated, matched]
  end

  def stamp_pointer!(ai_meta, cycle, fields)
    pointer = ai_meta['handoff']
    return unless pointer.is_a?(Hash) && cycle_matches?(pointer, cycle)

    ai_meta['handoff'] = pointer.merge(fields)
  end

  def cycle_matches?(stored_cycle, cycle)
    return stored_cycle['cycle_id'] == cycle['cycle_id'] if cycle['cycle_id'].present?

    stored_cycle['invited_at'] == cycle['invited_at']
  end

  def log_activity!(card, conversation, user_id, threshold_seconds)
    Crm::ActivityLogger.new(
      card: card,
      actor: nil,
      event_type: 'ai_handoff_escalation',
      conversation: conversation,
      payload: {
        assignee_id: user_id,
        threshold_seconds: threshold_seconds.to_i
      }
    ).perform
  end

  def parse_time(value)
    Time.zone.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end
end
