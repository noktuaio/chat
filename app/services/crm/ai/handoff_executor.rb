module Crm
  module Ai
    # Executes an AI-decided handoff to a human: assigns the conversation to an
    # inbox member and stops the AgentBot. Idempotent and loop-safe — assigning
    # re-enqueues evaluation (assignee_changed -> SyncConversationCardJob), so the
    # guards below MUST short-circuit before any side effect.
    class HandoffExecutor
      Result = Struct.new(:status, :assignee, :error, keyword_init: true)
      # Limita o histórico R3 por card para evitar crescimento indefinido do JSONB.
      HANDOFF_CYCLES_CAP = 20

      def initialize(card:, handoff:, trigger: 'message')
        @card = card
        @handoff = normalize(handoff)
        @trigger = trigger
        @conversation = card.primary_conversation
      end

      def perform
        blocked = blocked_reason
        return skip_blocked(blocked) if blocked

        if invite_mode?
          agent = select_agent(require_online: false)
          return skip('no_eligible_agent') if agent.blank?

          return invite(agent)
        end

        agent = select_agent(require_online: settings[:prefer_online])
        if agent.blank?
          return hold_online if held_for_online?

          return skip('no_eligible_agent')
        end

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

      # Só "transferir" dispara o handoff. "consultar" fica em standby (fase 2) e
      # "continuar" segue o atendimento — ambos NÃO atribuem/convidam. Fallback ao
      # should_handoff legado enquanto respostas antigas (sem intent) circulam no rollout.
      def requested?
        intent = @handoff[:intent].to_s
        return true if intent == 'transferir'
        return false if %w[continuar consultar].include?(intent)

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
      def select_agent(require_online:)
        @member_selector = Crm::Ai::HandoffMemberSelector.new(
          inbox: @conversation.inbox,
          account_id: @card.account_id,
          mode: settings[:selector_mode],
          prefer_online: settings[:prefer_online],
          require_online: require_online,
          suggested_name: @handoff[:suggested_agent],
          pool_type: settings[:pool_type],
          pool_id: settings[:pool_id]
        )
        @member_selector.perform
      end

      def held_for_online?
        @member_selector&.held_for_online?
      end

      def invite_mode?
        settings[:handoff_mode] == 'r3_invite'
      end

      # R3: convida (participante + notificação), NÃO atribui, NÃO cala o bot. Grava
      # um CICLO de convite (invited_at, métrica de tempo-de-pega, PR2) + last_handoff_at
      # (cooldown). Se o agente não puder participar da caixa, o convite falha e nada é
      # gravado.
      #
      # @card.with_lock (FOR UPDATE) serializa o append no JSONB: blocked_reason roda
      # ANTES de qualquer lock, então dois avaliadores concorrentes poderiam passar
      # ambos pela guarda de cooldown e sobrescrever o append um do outro (cycle_id
      # duplicado / ciclo sem convite). Sob lock, recarrega metadata fresco e RE-checa
      # cooldown — o 2º vira no-op limpo. Mesma salvaguarda do HandoffPickupRecorder.
      def invite(agent)
        outcome = nil
        @card.with_lock do
          if recently_handed_off?
            outcome = skip('cooldown')
            next
          end

          invited = Crm::Ai::HandoffInviter.new(conversation: @conversation, agent: agent).perform
          raise ActiveRecord::Rollback unless invited

          stamp_handoff_metadata!(invited: true, invited_agent: agent)
          log_activity!(agent, event_type: 'ai_handoff_invite')
          outcome = Result.new(status: :invited, assignee: agent)
        end
        outcome || skip('invite_failed')
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

      def stamp_handoff_metadata!(invited: false, invited_agent: nil)
        metadata = (@card.metadata || {}).deep_dup
        now = Time.current.iso8601
        ai = (metadata['ai'] || {}).merge('last_handoff_at' => now)
        ai.delete('handoff_hold')
        ai = append_invite_cycle(ai, now, invited_agent) if invited
        metadata['ai'] = ai
        @card.update!(metadata: metadata)
      end

      # R3: cada convite é um CICLO. Mantém o histórico em ai['handoffs'] (lista) +
      # um ponteiro ai['handoff'] p/ o ciclo ativo (retrocompat: PickupRecorder/UI
      # leem o blob único). Um novo ciclo SUPERSEDE o anterior ainda aberto (marca
      # canceled_at) — fecha o convite órfão SEM sobrescrever a métrica do ciclo
      # anterior (U11: antes o 2º convite pisava em invited_at do 1º).
      def append_invite_cycle(ai_meta, now, agent)
        cycles = supersede_open_cycles(normalized_cycles(ai_meta), now)
        cycle = { 'cycle_id' => next_cycle_id(cycles), 'invited_at' => now, 'invited_agent_id' => agent.id }
        # O ponteiro sempre referencia o ciclo recém-criado; manter a cauda preserva
        # esse ciclo e descarta apenas histórico antigo já fora da janela operacional.
        capped_cycles = (cycles + [cycle]).last(HANDOFF_CYCLES_CAP)
        ai_meta.merge('handoffs' => capped_cycles, 'handoff' => cycle)
      end

      # Semeia a lista a partir do blob legado (convite gravado antes do array) para
      # não perder um convite em voo no 1º ciclo pós-deploy.
      def normalized_cycles(ai_meta)
        cycles = ai_meta['handoffs']
        return cycles if cycles.is_a?(Array) && cycles.present?

        legacy = ai_meta['handoff']
        return [] if legacy.blank? || legacy['invited_at'].blank?

        [legacy.merge('cycle_id' => 1)]
      end

      def supersede_open_cycles(cycles, now)
        cycles.map do |cycle|
          open = cycle['picked_up_at'].blank? && cycle['canceled_at'].blank? &&
                 cycle['expired_at'].blank? && cycle['escalated_at'].blank?
          open ? cycle.merge('canceled_at' => now) : cycle
        end
      end

      def next_cycle_id(cycles)
        (cycles.map { |cycle| cycle['cycle_id'].to_i }.max || 0) + 1
      end

      def log_activity!(agent, event_type: 'ai_handoff')
        Crm::ActivityLogger.new(
          card: @card,
          actor: nil,
          event_type: event_type,
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

      def skip_blocked(reason)
        # Cooldown é transitório: mantém o marcador para o drain retentar depois
        # da janela. Os demais motivos são terminais ou refletem a intenção atual
        # do cliente, então limpam o hold órfão.
        clear_handoff_hold! unless reason == 'cooldown'
        skip(reason)
      end

      def hold_online
        stamp_handoff_hold!
        Result.new(status: :held_online, error: 'no_online_agent')
      end

      # R2 drain: "segurar online" NÃO é handoff — não atribui, não cala bot e
      # não grava cooldown. Persiste só o payload normalizado para o cron tentar
      # novamente a MESMA seleção quando alguém ficar online, sem chamar IA de novo.
      def stamp_handoff_hold!
        metadata = (@card.metadata || {}).deep_dup
        previous_hold = metadata.dig('ai', 'handoff_hold') || {}
        ai = (metadata['ai'] || {}).merge(
          'handoff_hold' => {
            'held_at' => previous_hold['held_at'].presence || Time.current.iso8601,
            'handoff' => @handoff.to_h
          }
        )
        metadata['ai'] = ai
        @card.update!(metadata: metadata)
      end

      # Limpa marcador órfão quando o card deixou de ser drenável (atribuído,
      # sem conversa, config desligada etc.) ou quando o assign efetivo já gravou
      # o handoff. Sem isso o cron continuaria varrendo lixo sem chance de ação.
      def clear_handoff_hold!
        metadata = (@card.metadata || {}).deep_dup
        ai = metadata['ai'] || {}
        return unless ai.key?('handoff_hold')

        metadata['ai'] = ai.except('handoff_hold')
        @card.update!(metadata: metadata)
      end
    end
  end
end
