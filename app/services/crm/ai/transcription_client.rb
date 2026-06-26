module Crm
  module Ai
    # Transcribes an audio attachment to text using the CRM hook's OpenAI
    # credential (independent of Captain). Mirrors the EE
    # Messages::AudioTranscriptionService mechanics (temp file, 25MB limit,
    # temperature 0.0) and writes to the shared cache key
    # `attachment.meta['transcribed_text']`.
    class TranscriptionClient
      class Error < StandardError; end

      def initialize(credential:)
        @credential = credential
      end

      def transcribe(attachment)
        blob = attachment.file&.blob
        return if blob.blank?
        return if blob.byte_size > Config::TRANSCRIPTION_BYTE_LIMIT

        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        temp_file_path = download_to_temp(blob)
        File.open(temp_file_path, 'rb') do |file|
          response = client.audio.transcribe(
            parameters: {
              model: Config::TRANSCRIBE_MODEL,
              file: file,
              temperature: 0.0,
              language: 'pt'
            }
          )
          response['text']
        end
      rescue StandardError => e
        log_failure(e, attachment: attachment, blob: blob, started_at: started_at)
        raise
      ensure
        FileUtils.rm_f(temp_file_path) if temp_file_path.present?
      end

      private

      def client
        @client ||= OpenAI::Client.new(
          access_token: @credential[:api_key],
          uri_base: safe_uri_base
        )
      end

      # SSRF: o `api_base` pode vir do hook da conta (api_base custom OpenAI-compatível). Mesmo guard do
      # ResponsesClient/EmbeddingService — bloqueia host/IP interno/loopback/metadata para o backend não
      # postar o arquivo de áudio em destino controlado pelo tenant. Blank => default da gem (OpenAI).
      def safe_uri_base
        base = @credential[:api_base].to_s.strip
        return if base.blank?

        ::Crm::Ai::ApiBaseGuard.validate!(base)
      rescue ::Crm::Ai::ApiBaseGuard::BlockedError
        raise Error, 'invalid_api_base' # mensagem curta; nunca loga conteúdo/credencial
      end

      def download_to_temp(blob)
        temp_dir = Rails.root.join('tmp/uploads/crm-ai-transcriptions')
        FileUtils.mkdir_p(temp_dir)
        temp_file_name = "#{blob.key}-#{blob.filename}"
        if blob.filename.extension_without_delimiter.blank?
          extension = extension_from_content_type(blob.content_type)
          temp_file_name = "#{temp_file_name}.#{extension}" if extension.present?
        end
        temp_file_path = File.join(temp_dir, temp_file_name)
        File.open(temp_file_path, 'wb') do |file|
          blob.open { |blob_file| IO.copy_stream(blob_file, file) }
        end
        temp_file_path
      end

      def extension_from_content_type(content_type)
        subtype = content_type.to_s.downcase.split(';').first.to_s.split('/').last.to_s
        return if subtype.blank?

        { 'x-m4a' => 'm4a', 'x-wav' => 'wav', 'x-mp3' => 'mp3' }.fetch(subtype, subtype)
      end

      def log_failure(error, attachment:, blob:, started_at:)
        latency = started_at ? ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round : nil
        Rails.logger.error(
          "[crm][ai][openai_error] operation=audio.transcription model=#{Config::TRANSCRIBE_MODEL} " \
          "error_type=#{error.class.name} credential_source=#{@credential[:source]} api_host=#{api_host} " \
          "attachment_id=#{attachment&.id} blob_byte_size=#{blob&.byte_size} latency_ms=#{latency} " \
          "message=#{error.message.to_s.truncate(300)}"
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
