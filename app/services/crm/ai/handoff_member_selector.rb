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
    #   require_online -> restringe a seleção a agentes online quando true (default false)
    #   suggested_name -> nome sugerido pela IA (apenas em mode 'direct')
    #   pool_type      -> 'inbox' (default) | 'user' (restringe a um membro da inbox)
    #   pool_id        -> id do usuário quando pool_type='user'
    #
    # Retorna User | nil (nil = sem membro elegível).
    class HandoffMemberSelector
      def initialize(
        inbox:,
        account_id:,
        mode: 'round_robin',
        prefer_online: true,
        require_online: false,
        suggested_name: nil,
        pool_type: 'inbox',
        pool_id: nil
      )
        @inbox = inbox
        @account_id = account_id
        @mode = mode
        @prefer_online = prefer_online
        @require_online = require_online
        @suggested_name = suggested_name
        @pool_type = pool_type
        @pool_id = pool_id
      end

      def perform
        select_agent
      end

      def held_for_online?
        @require_online && eligible_members.present? && online_members.empty?
      end

      private

      def eligible_members
        @eligible_members ||= begin
          members = @inbox ? @inbox.members.to_a : []
          if @pool_type == 'user' && @pool_id.present?
            members.select { |user| user.id == @pool_id }.presence || members
          else
            members
          end
        end
      end

      # direct: assign to the agent the AI matched by name (must be an inbox
      # member, and online when required); fall back to round-robin if no match (stay flexible).
      # round_robin: balanced pick, preferring online agents when configured.
      def select_agent
        return if eligible_members.empty?
        return if held_for_online?

        if @mode == 'direct'
          matched = match_suggested_agent
          return matched if matched.present?
        end
        round_robin_agent
      end

      def match_suggested_agent
        name = @suggested_name.to_s.strip.downcase
        return if name.blank?

        search_pool.find { |user| user.name.to_s.strip.downcase == name } ||
          search_pool.find do |user|
            member = user.name.to_s.downcase
            member.present? && (member.include?(name) || name.include?(member))
          end
      end

      def search_pool
        @require_online ? preferred_pool : eligible_members
      end

      def round_robin_agent
        pool = preferred_pool
        counts = @inbox.conversations.open.where(assignee_id: pool.map(&:id)).group(:assignee_id).count
        pool.min_by { |user| counts[user.id] || 0 }
      end

      # Prefer online agents; when online is required, keep only online agents.
      # Otherwise, if none online (or presence not tracked), assign anyway.
      def preferred_pool
        return online_members if @require_online
        return eligible_members unless @prefer_online

        online_members.presence || eligible_members
      end

      def online_members
        @online_members ||= eligible_members.select { |user| online_agent_ids.include?(user.id) }
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
