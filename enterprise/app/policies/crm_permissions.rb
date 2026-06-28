# Shared helper for CRM Pundit policies (EE overlay).
#
# - Administrators keep full CRM access.
# - Plain agents (account_user present, NO custom_role) keep their day-to-day CRM
#   access (view, cards, reports) but NOT admin-grade configuration nor AI
#   features. This mirrors the OSS policies, which gate pipelines/stages/
#   automations/inbox settings/integration tokens behind administrator?.
#   Previously plain agents were granted every key, letting any agent alter
#   pipelines/automations, read/issue integration tokens and change pipeline AI
#   settings — a privilege escalation.
# - Custom-role users are gated by the granular crm_* keys (crm_admin implies all);
#   AI capabilities remain available to roles explicitly granted crm_manage_ai.
module CrmPermissions
  # Keys never granted to a plain (non-custom-role) agent.
  # - crm_manage_pipelines: pipelines, stages, automations, pipeline inboxes, inbox settings
  # - crm_manage_ai: pipeline AI settings + AI actions on cards (cost-incurring; needs an explicit role)
  # - crm_admin: integration tokens (full CRM credential lifecycle)
  PLAIN_AGENT_DENIED_KEYS = %w[crm_manage_pipelines crm_manage_ai crm_admin].freeze

  def crm_permission?(key)
    return false if account_user.blank?
    return true if account_user.administrator?

    custom_role = account_user.custom_role
    return PLAIN_AGENT_DENIED_KEYS.exclude?(key) if custom_role.blank?

    permissions = custom_role.permissions
    permissions.include?('crm_admin') || permissions.include?(key)
  end
end
