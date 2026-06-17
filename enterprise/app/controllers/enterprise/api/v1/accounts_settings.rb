module Enterprise::Api::V1::AccountsSettings
  FIRST_TOUCH_COOKIE = 'cw_first_touch_attribution'.freeze
  LAST_TOUCH_COOKIE = 'cw_last_touch_attribution'.freeze

  def create
    super
    record_marketing_attribution
  end

  private

  # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def record_marketing_attribution
    return unless ChatwootApp.chatwoot_cloud? && @account

    first_touch = attribution_cookie(FIRST_TOUCH_COOKIE)
    last_touch = attribution_cookie(LAST_TOUCH_COOKIE)
    return unless first_touch || last_touch

    existing_attribution = @account.internal_attributes['marketing_attribution'] || {}
    @account.update!(
      internal_attributes: @account.internal_attributes.merge(
        'marketing_attribution' => {
          'first_touch' => existing_attribution['first_touch'].presence || first_touch || last_touch,
          'last_touch' => last_touch || first_touch,
          'captured_from' => 'cookie',
          'stored_at' => Time.current.iso8601
        }
      )
    )
  rescue StandardError => e
    ChatwootExceptionTracker.new(e).capture_exception
  end
  # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  def attribution_cookie(cookie_name)
    JSON.parse(CGI.unescape(cookies[cookie_name].to_s)) if cookies[cookie_name].present?
  end

  def permitted_settings_attributes
    super + [{ conversation_required_attributes: [] }]
  end
end
