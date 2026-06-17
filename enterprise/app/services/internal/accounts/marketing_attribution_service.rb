# frozen_string_literal: true

class Internal::Accounts::MarketingAttributionService
  FIRST_TOUCH_COOKIE = 'cw_first_touch_attribution'
  LAST_TOUCH_COOKIE = 'cw_last_touch_attribution'

  pattr_initialize [:account!, :cookies!]

  def perform
    return unless ChatwootApp.chatwoot_cloud?

    first_touch = attribution_cookie(FIRST_TOUCH_COOKIE)
    last_touch = attribution_cookie(LAST_TOUCH_COOKIE)
    return unless first_touch || last_touch

    account.update!(
      internal_attributes: account.internal_attributes.merge(
        'marketing_attribution' => {
          'first_touch' => first_touch,
          'last_touch' => last_touch,
          'captured_from' => 'cookie',
          'stored_at' => Time.current.iso8601
        }.compact
      )
    )
  end

  private

  def attribution_cookie(cookie_name)
    JSON.parse(CGI.unescape(cookies[cookie_name].to_s)) if cookies[cookie_name].present?
  end
end
