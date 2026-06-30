# frozen_string_literal: true

require 'net/http'
require 'uri'

class Autonomia::Financial::Client
  class Error < StandardError
    attr_reader :status, :payload

    def initialize(message, status: :bad_gateway, payload: {})
      super(message)
      @status = status
      @payload = payload
    end
  end

  ENDPOINTS = {
    subscription: '/financial/me/subscription',
    billing_preview: '/financial/me/billing-preview',
    invoices: '/financial/me/invoices',
    payments: '/financial/me/payments'
  }.freeze

  def initialize(authorization_token:)
    @authorization_token = authorization_token
  end

  def fetch!(resource)
    path = ENDPOINTS.fetch(resource)
    get_json(path)
  end

  private

  attr_reader :authorization_token

  def get_json(path)
    uri = URI.join(base_url, path)
    request = Net::HTTP::Get.new(uri)
    request['Accept'] = 'application/json'
    request['Authorization'] = "Bearer #{authorization_token}"

    response = Net::HTTP.start(
      uri.host,
      uri.port,
      use_ssl: uri.scheme == 'https',
      open_timeout: 5,
      read_timeout: 15
    ) { |http| http.request(request) }

    payload = JSON.parse(response.body.presence || '{}')
    return payload if response.is_a?(Net::HTTPSuccess)
    return nil if response.code.to_i == 404

    raise Error.new(error_message(payload, response), status: response.code.to_i, payload: payload)
  rescue JSON::ParserError
    raise Error.new('Resposta invalida do financeiro Autonom.ia.')
  rescue KeyError
    raise Error.new('Recurso financeiro nao suportado.')
  rescue SocketError, Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED => e
    raise Error.new("Nao foi possivel consultar o financeiro Autonom.ia: #{e.message}")
  end

  def error_message(payload, response)
    error = payload['error']
    return error['message'] if error.is_a?(Hash) && error['message'].present?

    payload['message'] || error || "Financeiro Autonom.ia retornou HTTP #{response.code}."
  end

  def base_url
    ENV.fetch('AUTONOMIA_FINANCIAL_API_BASE_URL', 'https://financial.api-autonomia.com')
  end
end
