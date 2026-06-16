module Integrations::Cloudflare::RealtimeKitCredentialsValidator
  Result = Data.define(:success?, :error)

  BASE_URL = 'https://api.cloudflare.com/client/v4'.freeze
  TIMEOUT_SECONDS = 5

  def self.valid?(account_id, app_id, api_token)
    validate(account_id, app_id, api_token).success?
  end

  def self.validate(account_id, app_id, api_token)
    return failure(:missing_credentials) if account_id.blank? || app_id.blank? || api_token.blank?

    token_result = validate_token(api_token)
    return token_result unless token_result.success?

    validate_realtimekit_app(account_id, app_id, api_token)
  rescue Faraday::Error => e
    Rails.logger.warn("[cloudflare-realtimekit-credentials-validator] #{e.class}: #{e.message}")
    success
  end

  def self.validate_token(api_token)
    response = connection.get("#{BASE_URL}/user/tokens/verify") do |req|
      req.headers['Authorization'] = "Bearer #{api_token}"
    end

    return success if transient_error?(response)

    body = parse_response(response)
    return success if response.status == 200 && body['success'] == true && body.dig('result', 'status') == 'active'

    failure(:invalid_api_token)
  end
  private_class_method :validate_token

  def self.validate_realtimekit_app(account_id, app_id, api_token)
    response = connection.get("#{BASE_URL}/accounts/#{account_id}/realtime/kit/apps") do |req|
      req.headers['Authorization'] = "Bearer #{api_token}"
    end

    return success if transient_error?(response)
    return failure(:invalid_account_or_permissions) unless response.status == 200

    apps = parse_response(response)['data'] || []
    return success if apps.any? { |app| app['id'] == app_id }

    failure(:app_not_found)
  end
  private_class_method :validate_realtimekit_app

  def self.connection
    Faraday.new do |f|
      f.options.timeout = TIMEOUT_SECONDS
      f.options.open_timeout = TIMEOUT_SECONDS
    end
  end
  private_class_method :connection

  def self.parse_response(response)
    JSON.parse(response.body)
  rescue JSON::ParserError
    {}
  end
  private_class_method :parse_response

  def self.transient_error?(response)
    response.status >= 500
  end
  private_class_method :transient_error?

  def self.success
    Result.new(true, nil)
  end
  private_class_method :success

  def self.failure(error)
    Result.new(false, error)
  end
  private_class_method :failure
end
