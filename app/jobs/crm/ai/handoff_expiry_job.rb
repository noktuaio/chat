class Crm::Ai::HandoffExpiryJob < ApplicationJob
  queue_as :scheduled_jobs

  CANDIDATE_CARDS_SQL = <<~SQL.squish
    CASE
      WHEN jsonb_typeof(metadata #> '{ai,handoffs}') = 'array'
      THEN jsonb_array_length(metadata #> '{ai,handoffs}') > 0
      ELSE FALSE
    END
  SQL

  def perform
    return unless Crm::Ai::Config.enabled?

    Crm::Pipeline.active.find_each do |pipeline|
      candidate_cards(pipeline).find_each { |card| expire_card_if_eligible(card) }
    end
  end

  private

  def candidate_cards(pipeline)
    pipeline.cards.open.where(CANDIDATE_CARDS_SQL)
  end

  def expire_card_if_eligible(card)
    settings = Crm::Ai::Config.handoff_settings(card.stage, card.pipeline)
    return unless settings[:enabled] && settings[:handoff_mode] == 'r3_invite'

    expire_card(card, settings[:invite_ttl_seconds].to_i)
  end

  # Lock por card porque pickup/cancelamento/novo convite também escrevem no mesmo
  # JSONB; o recheck sob lock evita expirar um ciclo que acabou de ser pego.
  def expire_card(card, ttl_seconds)
    card.with_lock do
      metadata = (card.metadata || {}).deep_dup
      ai_meta = (metadata['ai'] || {}).to_h
      updated_cycles, changed = expire_cycles(ai_meta['handoffs'], ttl_seconds)
      next unless changed

      card.update!(metadata: metadata_with_expired_handoff(metadata, ai_meta, updated_cycles))
    end
  end

  def expire_cycles(cycles, ttl_seconds)
    return [cycles, false] unless cycles.is_a?(Array)

    expired_at = Time.current.iso8601
    cutoff = ttl_seconds.seconds.ago
    changed = false
    updated_cycles = cycles.map do |cycle|
      if expirable_cycle?(cycle, cutoff)
        changed = true
        cycle.merge('expired_at' => expired_at)
      else
        cycle
      end
    end
    [updated_cycles, changed]
  end

  def metadata_with_expired_handoff(metadata, ai_meta, updated_cycles)
    updated_ai = ai_meta.merge('handoffs' => updated_cycles)
    updated_ai = updated_ai.merge('handoff' => updated_pointer(ai_meta['handoff'], updated_cycles)) if ai_meta.key?('handoff')
    metadata.merge('ai' => updated_ai)
  end

  def expirable_cycle?(cycle, cutoff)
    return false unless cycle.is_a?(Hash)
    return false if cycle['invited_at'].blank?
    return false if cycle['picked_up_at'].present? || cycle['canceled_at'].present? || cycle['expired_at'].present?

    invited_at = parse_time(cycle['invited_at'])
    invited_at.present? && invited_at < cutoff
  end

  def updated_pointer(pointer, cycles)
    return pointer unless pointer.is_a?(Hash)

    expired_cycle = cycles.find { |cycle| pointer_matches_cycle?(pointer, cycle) && cycle['expired_at'].present? }
    return pointer if expired_cycle.blank?

    pointer.merge('expired_at' => expired_cycle['expired_at'])
  end

  def pointer_matches_cycle?(pointer, cycle)
    return false unless cycle.is_a?(Hash)
    return cycle['cycle_id'] == pointer['cycle_id'] if pointer['cycle_id'].present?

    cycle['invited_at'] == pointer['invited_at']
  end

  def parse_time(value)
    Time.zone.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end
end
