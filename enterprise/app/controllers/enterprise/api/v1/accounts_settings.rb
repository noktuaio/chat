module Enterprise::Api::V1::AccountsSettings
  FIRST_TOUCH_COOKIE = 'cw_first_touch_attribution'.freeze
  LAST_TOUCH_COOKIE = 'cw_last_touch_attribution'.freeze

  def create
    super
    record_marketing_attribution
  end

  private

  def record_marketing_attribution
    return unless ChatwootApp.chatwoot_cloud?
    return if @account.blank?

    first_touch, last_touch = attribution_cookies
    return if first_touch.blank? && last_touch.blank?

    store_marketing_attribution(first_touch, last_touch)
  rescue StandardError => e
    ChatwootExceptionTracker.new(e).capture_exception
  end

  def attribution_cookies
    [
      attribution_cookie(FIRST_TOUCH_COOKIE),
      attribution_cookie(LAST_TOUCH_COOKIE)
    ]
  end

  def store_marketing_attribution(first_touch, last_touch)
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
  end

  def attribution_cookie(cookie_name)
    return if cookies[cookie_name].blank?

    JSON.parse(CGI.unescape(cookies[cookie_name].to_s))
  rescue JSON::ParserError, ArgumentError
    nil
  end

  def permitted_settings_attributes
    super + [{ conversation_required_attributes: [] }]
  end
end
