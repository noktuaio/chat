require 'json'
require 'net/http'

class Crm::Ai::ExchangeRate
  API_URL = 'https://economia.awesomeapi.com.br/last/USD-BRL'.freeze
  CURRENT_CACHE_KEY = 'crm:ai:usd_brl:current'.freeze
  LAST_CACHE_KEY = 'crm:ai:usd_brl:last'.freeze
  CURRENT_TTL = 30.minutes
  HTTP_TIMEOUT = 2

  class << self
    def current
      cached_rate(CURRENT_CACHE_KEY) || cached_rate(LAST_CACHE_KEY) || unavailable_payload
    end

    def refresh!
      rate = fetch_rate
      return unavailable_payload if rate.blank?

      payload = rate_payload(rate)
      Rails.cache.write(CURRENT_CACHE_KEY, payload, expires_in: CURRENT_TTL)
      Rails.cache.write(LAST_CACHE_KEY, payload)
      payload.merge(rate_unavailable: false)
    rescue StandardError => e
      Rails.logger.warn("[crm][ai][exchange_rate] refresh failed: #{e.class}: #{e.message}")
      unavailable_payload
    end

    private

    def cached_rate(key)
      payload = Rails.cache.read(key)
      rate = rate_from_payload(payload)
      return if rate.blank?

      {
        rate: rate,
        fetched_at: payload[:fetched_at] || payload['fetched_at'],
        rate_unavailable: false,
        stale: key == LAST_CACHE_KEY
      }
    rescue StandardError => e
      Rails.logger.warn("[crm][ai][exchange_rate] cache read failed key=#{key}: #{e.class}: #{e.message}")
      nil
    end

    def fetch_rate
      uri = URI.parse(API_URL)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: HTTP_TIMEOUT, read_timeout: HTTP_TIMEOUT) do |http|
        http.get(uri.request_uri, 'Accept' => 'application/json')
      end
      return unless response.is_a?(Net::HTTPSuccess)

      body = JSON.parse(response.body)
      bid = body.dig('USDBRL', 'bid')
      rate = BigDecimal(bid.to_s)
      rate.positive? ? rate : nil
    rescue JSON::ParserError, ArgumentError, TypeError, Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError => e
      Rails.logger.warn("[crm][ai][exchange_rate] fetch failed: #{e.class}: #{e.message}")
      nil
    end

    def rate_payload(rate)
      { rate: rate, fetched_at: Time.current.iso8601 }
    end

    def rate_from_payload(payload)
      return if payload.blank?

      rate = payload[:rate] || payload['rate']
      BigDecimal(rate.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def unavailable_payload
      { rate: nil, rate_unavailable: true }
    end
  end
end
