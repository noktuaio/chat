module Crm
  module Ai
    # Executes an AI-decided handoff to a human: assigns the conversation to an
    # inbox member and stops the AgentBot. Idempotent and loop-safe — assigning
    # re-enqueues evaluation (assignee_changed -> SyncConversationCardJob), so the
    # guards below MUST short-circuit before any side effect.
    class HandoffExecutor
      Result = Struct.new(:status, :assignee, :error, keyword_init: true)

      def initialize(card:, handoff:, trigger: 'message')
        @card = card
        @handoff = normalize(handoff)
        @trigger = trigger
        @conversation = card.primary_conversation
      end

      def perform
        blocked = blocked_reason
        return skip(blocked) if blocked

        agent = select_agent
        return skip('no_eligible_agent') if agent.blank?
        return skip('assignment_failed') unless assign!(agent)

        Result.new(status: :handed_off, assignee: agent)
      end

      private

      # Primeira guarda que falha (ou nil se pode prosseguir). Idempotente/loop-safe:
      # atribuir re-enfileira avaliação, então estas guardas têm de curto-circuitar antes
      # de qualquer efeito colateral.
      def blocked_reason
        return 'not_requested' unless requested?
        return 'disabled' unless settings[:enabled]
        return 'no_conversation' if @conversation.blank?
        return 'already_assigned' if @conversation.assignee_id.present?
        return 'cooldown' if recently_handed_off?

        nil
      end

      def normalize(handoff)
        return {} if handoff.blank?

        handoff.respond_to?(:with_indifferent_access) ? handoff.with_indifferent_access : handoff
      end

      def requested?
        ActiveModel::Type::Boolean.new.cast(@handoff[:should_handoff])
      end

      def settings
        @settings ||= Config.handoff_settings(@card.stage, @card.pipeline)
      end

      def recently_handed_off?
        last = (@card.metadata || {}).dig('ai', 'last_handoff_at')
        return false if last.blank?

        Time.parse(last.to_s) > Config::HANDOFF_COOLDOWN_SECONDS.seconds.ago
      rescue ArgumentError, TypeError
        false
      end

      # Seleção de membro delegada ao Crm::Ai::HandoffMemberSelector (lógica
      # extraída — round-robin/online/match por nome). Os parâmetros vêm do
      # settings do estágio/pipeline e do handoff sugerido pela IA.
      def select_agent
        Crm::Ai::HandoffMemberSelector.new(
          inbox: @conversation.inbox,
          account_id: @card.account_id,
          mode: settings[:mode],
          prefer_online: settings[:prefer_online],
          suggested_name: @handoff[:suggested_agent]
        ).perform
      end

      # Retorna true só se a atribuição efetivou. A primitiva revalida o agente em
      # account.users e devolve nil se ele não pertencer à conta (membro órfão/
      # cross-account) — nesse caso NÃO grava metadata/log nem cala o bot (evita
      # estado inconsistente: "passei pra Fulano" sem ter passado).
      def assign!(agent)
        assigned = false
        ActiveRecord::Base.transaction do
          # Caminho canônico de atribuição (mesmo do botão de atribuir da UI):
          # seta assignee + zera assignee_agent_bot (cala o bot) num só ponto.
          # NÃO é o motor round-robin nativo (auto_assignment v2) — quem decide o
          # agente continua sendo o HandoffMemberSelector do CRM.
          assigned = Conversations::AssignmentService.new(conversation: @conversation, assignee_id: agent.id).perform.present?
          raise ActiveRecord::Rollback unless assigned

          stamp_handoff_metadata!
          log_activity!(agent)
        end
        return false unless assigned

        # Stop the AgentBot: transitions pending->open and signals handoff.
        @conversation.bot_handoff!
        true
      end

      def stamp_handoff_metadata!
        metadata = (@card.metadata || {}).deep_dup
        metadata['ai'] = (metadata['ai'] || {}).merge('last_handoff_at' => Time.current.iso8601)
        @card.update!(metadata: metadata)
      end

      def log_activity!(agent)
        Crm::ActivityLogger.new(
          card: @card,
          actor: nil,
          event_type: 'ai_handoff',
          conversation: @conversation,
          payload: {
            assignee_id: agent.id,
            reason: @handoff[:reason].to_s[0, 300],
            mode: settings[:mode]
          }
        ).perform
      end

      def skip(reason)
        Result.new(status: :skipped, error: reason)
      end
    end
  end
end
