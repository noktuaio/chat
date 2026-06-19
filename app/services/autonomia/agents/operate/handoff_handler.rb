module Autonomia
  module Agents
    module Operate
      # Fase C "Operar" — HANDOFF. Encerra graciosamente a atuação do bot numa conversa e
      # devolve o atendimento ao humano.
      #
      # Disparado pelo Responder quando o Answerer pede handoff (handoff[:should]) ou não
      # produziu resposta utilizável (reply em branco — inclui erro/timeout do LLM já tratado
      # como handoff seguro na Fase B).
      #
      # Faz o MÍNIMO SEGURO e canônico:
      #   1. posta UMA mensagem graciosa ao cliente, pelo MESMO caminho channel-agnóstico do
      #      Responder (Messages::MessageBuilder como AgentBot nativo-espelho);
      #   2. (Fase D, ADITIVO) reatribui a conversa a um humano conforme a estratégia
      #      configurada no agente (handoff_strategy): inbox_member (round-robin),
      #      assign_member (User), assign_team (Team). Default 'none' = NÃO reatribui;
      #      reusa Crm::Ai::HandoffMemberSelector (lógica do Kanban) via HandoffAssigner;
      #   3. PARA o bot e devolve a conversa ao humano via Conversation#bot_handoff!, que já
      #      faz open! (pending→open) e emite CONVERSATION_BOT_HANDOFF. Sem alvo (none/erro)
      #      a conversa fica UNASSIGNED (humano pega na fila) — comportamento da Fase C.
      #
      # Reusa a LÓGICA de seleção do Kanban (não o gate card-cêntrico do HandoffExecutor)
      # e delega o registro do motivo no card ao CardHandoffLogger (que reusa o
      # Crm::ActivityLogger do CRM). Atribuir ANTES de bot_handoff! faz o card espelhar o
      # assignee humano via observer (reúso puro, sem novo código de card). Nunca vaza
      # instruction/scaffold/prompt nem o motivo bruto do LLM.
      class HandoffHandler
        Result = Struct.new(:status, :error, keyword_init: true) do
          def success?
            status == :ok
          end
        end

        def initialize(conversation:, agent_inbox:, result: nil)
          @conversation = conversation
          @agent_inbox = agent_inbox
          @agent = agent_inbox.agent
          @result = result
        end

        def perform
          # Lock por conversa: serializa handoffs concorrentes e torna o passo idempotente
          # mesmo sob retry do Sidekiq após um post bem-sucedido.
          # NÃO usar `return` dentro do bloco de `with_lock` (Rails 7.1 dispara ROLLBACK ao
          # sair da transação por non-local return). Usa-se guarda condicional interna.
          did_handoff = false
          @conversation.with_lock do
            # Só age se o bot ainda está no comando (humano não assumiu). Senão, no-op barato.
            if @conversation.pending?
              # Só posta a mensagem graciosa se ainda não existe uma (retry após post -> pula
              # o post e apenas completa o bot_handoff!).
              post_handoff_message! unless handoff_message_exists?
              # Fase D (ADITIVO): reatribuição real ao humano conforme a estratégia do agente.
              # No-op total quando handoff_strategy == 'none' (default) -> fluxo idêntico à Fase C.
              assign_human!
              @conversation.bot_handoff!
              did_handoff = true
            end
          end

          # Fase F (ADITIVO/best-effort): um evento por handoff EFETIVO (não em no-op de
          # retry). Fora da transação; EventLogger nunca levanta -> zero impacto no handoff.
          if did_handoff
            ::Autonomia::Agents::Operate::EventLogger.handed_off(
              agent: @agent, conversation: @conversation, result: @result
            )
          end
          Result.new(status: :ok)
        rescue StandardError => e
          Rails.logger.error("[Autonomia::Operate::HandoffHandler] conversation=#{@conversation&.id} #{e.class}")
          Result.new(status: :error, error: :handoff_failed)
        end

        private

        # Já existe a mensagem graciosa de handoff postada pelo bot NESTE CICLO?
        # Idempotência ESCOPADA ao ciclo atual: só conta um handoff posterior à
        # última mensagem PÚBLICA de entrada do cliente. Assim, um retry do Sidekiq
        # no mesmo ciclo (sem novo inbound) ainda pula o post duplicado; mas se a
        # conversa reabriu/voltou a pending após o cliente responder (novo ciclo),
        # a flag antiga NÃO suprime a nova mensagem graciosa.
        def handoff_message_exists?
          # `content_attributes` é coluna `json` populada via Rails `store(coder: JSON)`,
          # que grava o hash como STRING JSON (json-dentro-de-json). Por isso o operador
          # `->>` devolve NULL (o valor de topo é uma string, não um objeto) e NUNCA casa;
          # e no `::text` as aspas internas vêm ESCAPADAS (`\"autonomia_handoff\":true`).
          # Casa-se por regex tolerando a barra opcional. Sem isso a idempotência ficaria
          # sempre falsa (retry do Sidekiq -> mensagem graciosa duplicada).
          scope = @conversation.messages.outgoing.where(sender_type: 'AgentBot')
                               .where('content_attributes::text ~ ?', 'autonomia_handoff\\\\?":true')

          last_incoming_at = @conversation.messages.incoming.where(private: false)
                                          .reorder(id: :desc).limit(1).pick(:created_at)
          scope = scope.where('created_at > ?', last_incoming_at) if last_incoming_at.present?
          scope.exists?
        end

        # Caminho CANÔNICO channel-agnóstico (idêntico ao Responder#post_reply! e ao
        # Crm::FollowUps::MessageSender): cria uma Message outgoing tendo o AgentBot
        # nativo-espelho como sender. A entrega por canal é responsabilidade do core.
        def post_handoff_message!
          text = handoff_text
          return if text.blank?

          Messages::MessageBuilder.new(
            nil,
            @conversation,
            ActionController::Parameters.new(
              content: text,
              message_type: 'outgoing',
              sender_type: 'AgentBot',
              sender_id: @agent_inbox.agent_bot_id,
              private: false,
              content_attributes: { autonomia_agent_id: @agent.id, autonomia_handoff: true }
            )
          ).perform
        end

        # Mensagem graciosa: prefere a frase contextual gerada pelo Answerer. Se a IA falhou
        # ou o gate bloqueou a reply por segurança, usa uma variação curta de encaminhamento.
        # Nunca expõe instruction/scaffold nem o motivo bruto do LLM.
        def handoff_text
          @result&.reply.to_s.strip.presence || default_handoff_text
        end

        def default_handoff_text
          messages = Array(I18n.t('autonomia.agents.operate.handoff_defaults',
                                  default: [I18n.t('autonomia.agents.operate.handoff_default')]))
          messages.compact_blank[handoff_variant_index % messages.compact_blank.size]
        end

        def handoff_variant_index
          seed = [
            @conversation.id,
            @conversation.messages.incoming.reorder(id: :desc).limit(1).pick(:id),
            Time.current.to_date.to_s
          ].compact.join(':')
          seed.each_byte.sum
        end

        # Fase D — reatribuição real ao humano (ADITIVO). HandoffAssigner resolve o alvo
        # conforme a estratégia do agente; nil = 'none'/alvo inválido/erro -> mantém o
        # comportamento da Fase C (unassigned). Rede de segurança dupla: o Assigner já
        # rescue->nil e este método também rescue -> NUNCA bloqueia o bot_handoff!.
        def assign_human!
          target = HandoffAssigner.new(conversation: @conversation, agent_inbox: @agent_inbox).perform
          return if target.blank?

          if target.is_a?(Team)
            @conversation.update!(team: target)
          else
            @conversation.update!(assignee: target)
          end
          # Registro best-effort do motivo no card/timeline — REÚSO do CardHandoffLogger
          # (que já guarda por Crm::Config.enabled? + card presente e engole qualquer erro).
          CardHandoffLogger.new(conversation: @conversation, agent: @agent, target: target).perform
        rescue StandardError => e
          # e.message ajuda o diagnóstico operacional de reatribuições que "somem"
          # (ex.: validação de conversa/state machine). É erro de AR — não vaza
          # instruction/scaffold/prompt nem motivo bruto do LLM. Truncado por garantia.
          Rails.logger.warn("[Autonomia::Operate::HandoffHandler] handoff_assign_skipped conversation=#{@conversation&.id} #{e.class}: #{e.message.to_s[0, 120]}")
          # Não propaga: segue para bot_handoff! e a conversa fica unassigned.
        end
      end
    end
  end
end
