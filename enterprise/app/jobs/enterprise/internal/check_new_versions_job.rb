module Enterprise::Internal::CheckNewVersionsJob
  def perform
    super
    update_plan_info
    reconcile_premium_config_and_features
  end

  private

  def update_plan_info
    return if @instance_info.blank?

    if ChatwootApp.self_hosted_enterprise_configured?
      update_installation_config(key: 'INSTALLATION_PRICING_PLAN', value: 'enterprise')
      update_installation_config(
        key: 'INSTALLATION_PRICING_PLAN_QUANTITY',
        value: ENV.fetch('INSTALLATION_PRICING_PLAN_QUANTITY', 10_000).to_i
      )
    else
      update_installation_config(key: 'INSTALLATION_PRICING_PLAN', value: @instance_info['plan'])
      update_installation_config(key: 'INSTALLATION_PRICING_PLAN_QUANTITY', value: @instance_info['plan_quantity'])
    end

    update_installation_config(key: 'CHATWOOT_SUPPORT_WEBSITE_TOKEN', value: @instance_info['chatwoot_support_website_token'])
    update_installation_config(key: 'CHATWOOT_SUPPORT_IDENTIFIER_HASH', value: @instance_info['chatwoot_support_identifier_hash'])
    update_installation_config(key: 'CHATWOOT_SUPPORT_SCRIPT_URL', value: @instance_info['chatwoot_support_script_url'])
  end

  def update_installation_config(key:, value:)
    config = InstallationConfig.find_or_initialize_by(name: key)
    config.value = value
    config.locked = true
    config.save!
  end

  def reconcile_premium_config_and_features
    Internal::ReconcilePlanConfigService.new.perform
  end
end
