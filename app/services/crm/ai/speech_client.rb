module Crm
  module Ai
    # Text-to-speech via a OpenAI da conta (mesma credencial do whisper-1 / gpt-5.4). Espelha o
    # TranscriptionClient: usa `Crm::Ai::ApiBaseGuard` no `api_base` (anti-SSRF) e NUNCA loga o texto.
    # Saída `opus` (formato de voz nativo do WhatsApp). Retorna os BYTES do áudio, ou nil.
    class SpeechClient
      class Error < StandardError; end

      def initialize(credential:)
        @credential = credential
      end

      # text -> bytes (opus). `voice` = nome da voz OpenAI (ex.: 'marin'/'cedar'). `instructions` =
      # direcionamento de fala (entonação/pronúncia/ritmo); só enviado quando presente. nil se texto vazio.
      def synthesize(text, voice:, instructions: nil)
        input = text.to_s.strip[0, Config::TTS_CHAR_LIMIT].to_s
        return if input.blank? || voice.to_s.blank?

        params = { model: Config::TTS_MODEL, input: input, voice: voice.to_s, response_format: 'opus' }
        steer = instructions.to_s.strip
        params[:instructions] = steer if steer.present?

        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        data = client.audio.speech(parameters: params)
        data.presence
      rescue StandardError => e
        log_failure(e, voice: voice, started_at: started_at)
        raise
      end

      private

      def client
        @client ||= OpenAI::Client.new(access_token: @credential[:api_key], uri_base: safe_uri_base)
      end

      # Mesmo guard SSRF do TranscriptionClient/ResponsesClient. Blank => default da gem (OpenAI).
      def safe_uri_base
        base = @credential[:api_base].to_s.strip
        return if base.blank?

        ::Crm::Ai::ApiBaseGuard.validate!(base)
      rescue ::Crm::Ai::ApiBaseGuard::BlockedError
        raise Error, 'invalid_api_base'
      end

      def log_failure(error, voice:, started_at:)
        latency = started_at ? ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round : nil
        Rails.logger.error(
          "[crm][ai][openai_error] operation=audio.speech model=#{Config::TTS_MODEL} " \
          "error_type=#{error.class.name} credential_source=#{@credential[:source]} api_host=#{api_host} " \
          "voice=#{voice} latency_ms=#{latency} message=#{error.message.to_s.truncate(300)}"
        )
      end

      def api_host
        base = @credential[:api_base].to_s.strip.presence || 'https://api.openai.com'
        URI.parse(base).host
      rescue StandardError
        nil
      end
    end
  end
end
