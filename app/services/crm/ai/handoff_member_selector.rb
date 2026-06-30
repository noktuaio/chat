module Crm
  module Ai
    # Seletor de membro humano para handoff — lógica de seleção EXTRAÍDA (verbatim)
    # do HandoffExecutor (round-robin por carga de conversas abertas, preferência por
    # online, match direto por nome sugerido pela IA). Usado pelo Kanban
    # (HandoffExecutor#select_agent delega aqui).
    #
    # Parâmetros:
    #   inbox          -> Inbox cujos membros formam o pool elegível
    #   account_id     -> conta (para presença/online)
    #   mode           -> 'round_robin' (default) | 'direct' (tenta casar suggested_name)
    #   prefer_online  -> prioriza agentes online quando true (default true)
    #   suggested_name -> nome sugerido pela IA (apenas em mode 'direct')
    #
    # Retorna User | nil (nil = sem membro elegível).
    class HandoffMemberSelector
      def initialize(inbox:, account_id:, mode: 'round_robin', prefer_online: true, suggested_name: nil)
        @inbox = inbox
        @account_id = account_id
        @mode = mode
        @prefer_online = prefer_online
        @suggested_name = suggested_name
      end

      def perform
        select_agent
      end

      private

      def eligible_members
        @eligible_members ||= @inbox ? @inbox.members.to_a : []
      end

      # direct: assign to the agent the AI matched by name (must be an inbox
      # member); fall back to round-robin if no match (stay flexible).
      # round_robin: balanced pick, preferring online agents when configured.
      def select_agent
        return if eligible_members.empty?

        if @mode == 'direct'
          matched = match_suggested_agent
          return matched if matched.present?
        end
        round_robin_agent
      end

      def match_suggested_agent
        name = @suggested_name.to_s.strip.downcase
        return if name.blank?

        eligible_members.find { |user| user.name.to_s.strip.downcase == name } ||
          eligible_members.find do |user|
            member = user.name.to_s.downcase
            member.present? && (member.include?(name) || name.include?(member))
          end
      end

      def round_robin_agent
        pool = preferred_pool
        counts = @inbox.conversations.open.where(assignee_id: pool.map(&:id)).group(:assignee_id).count
        pool.min_by { |user| counts[user.id] || 0 }
      end

      # Prefer online agents; if none online (or presence not tracked), assign
      # anyway — "pega quando entrar online" (locked decision).
      def preferred_pool
        return eligible_members unless @prefer_online

        online = eligible_members.select { |user| online_agent_ids.include?(user.id) }
        online.presence || eligible_members
      end

      def online_agent_ids
        @online_agent_ids ||= OnlineStatusTracker.get_available_users(@account_id)
                                                 .select { |_id, status| status == 'online' }
                                                 .keys.map(&:to_i)
      rescue StandardError
        []
      end
    end
  end
end
