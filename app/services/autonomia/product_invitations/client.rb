# frozen_string_literal: true

require 'net/http'
require 'uri'

class Autonomia::ProductInvitations::Client
  class Error < StandardError; end

  def create!(access_token:, payload:)
    uri = URI.parse(endpoint)
    request = Net::HTTP::Post.new(uri)
    request['Authorization'] = "Bearer #{access_token}"
    request['Content-Type'] = 'application/json'
    request.body = payload.to_json

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
      http.request(request)
    end
    body = JSON.parse(response.body.presence || '{}')
    return body if response.is_a?(Net::HTTPSuccess)

    raise Error, body['message'] || body['error'] || 'Nao foi possivel criar o convite no Auth.'
  rescue JSON::ParserError
    raise Error, 'Resposta invalida do Auth ao criar convite.'
  end

  private

  def endpoint
    ENV.fetch('AUTONOMIA_PRODUCT_INVITATIONS_ENDPOINT', 'https://auth.api-autonomia.com/auth/product-invitations')
  end
end
