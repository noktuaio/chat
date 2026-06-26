class Autonomia::Agents::EmbeddingService
  class EmbeddingError < StandardError; end

  # api_base padrão da OpenAI. O RubyLLM já tem o seu próprio default (com o path correto), então
  # quando a credencial da conta vem com este host "pelado" (sem /v1) NÃO repassamos o base — senão
  # a URL de embeddings sai errada e o provedor responde erro. Só repassamos base de provedor custom.
  OPENAI_DEFAULT_BASE = 'https://api.openai.com'.freeze

  def initialize(account:)
    Llm::Config.initialize!
    @account = account
    @model = InstallationConfig.find_by(name: 'CAPTAIN_EMBEDDING_MODEL')&.value.presence ||
             LlmConstants::DEFAULT_EMBEDDING_MODEL
  end

  # text -> Array<Float> (1536). Retorna [] se vazio. RubyLLM::Error -> EmbeddingError.
  # Usa a chave OpenAI DA CONTA (mesma do Construtor/Answerer, via CredentialResolver), pois a config
  # GLOBAL do RubyLLM (Llm::Config) não tem chave nesta instalação (chave é por conta).
  def embed(text)
    return [] if text.blank?

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    context.embed(text, model: @model).vectors
  rescue RubyLLM::Error => e
    log_failure(e, started_at: started_at)
    raise EmbeddingError, "Failed to create an embedding: #{e.message}"
  end

  # Array<String> -> Array<Array<Float>> (batch; itera embed, MVP)
  def embed_batch(texts)
    Array(texts).map { |text| embed(text) }
  end

  private

  # Contexto RubyLLM com a chave da conta. Memoizado (reusado no batch). Não repassa o api_base
  # quando é o host padrão da OpenAI (deixa o RubyLLM usar o default correto).
  def context
    @context ||= begin
      cred = Crm::Ai::CredentialResolver.new(account: @account).resolve
      raise EmbeddingError, 'ai_not_configured' if cred.blank?

      base = cred[:api_base].to_s.chomp('/')
      base = nil if base.blank? || base == OPENAI_DEFAULT_BASE
      # SSRF: api_base custom controlado pela conta é validado (HTTPS + bloqueio de host/IP
      # interno/loopback/link-local/metadata, literal E resolvido por DNS) ANTES de tocar a rede —
      # mesmo guard do Crm::Ai::ResponsesClient (paridade). Host interno -> EmbeddingError.
      if base.present?
        begin
          base = ::Crm::Ai::ApiBaseGuard.validate!(base)
        rescue ::Crm::Ai::ApiBaseGuard::BlockedError
          raise EmbeddingError, 'invalid_api_base'
        end
      end
      RubyLLM.context do |config|
        config.openai_api_key = cred[:api_key]
        config.openai_api_base = base if base.present?
      end
    end
  end

  def log_failure(error, started_at:)
    latency = started_at ? ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round : nil
    Rails.logger.error(
      "[crm][ai][openai_error] operation=autonomia.embedding model=#{@model} error_type=#{error.class.name} " \
      "account_id=#{@account&.id} api_host=#{api_host} latency_ms=#{latency} " \
      "message=#{error.message.to_s.truncate(300)}"
    )
  end

  def api_host
    cred = Crm::Ai::CredentialResolver.new(account: @account).resolve
    base = cred.to_h[:api_base].to_s.strip.presence || OPENAI_DEFAULT_BASE
    URI.parse(base).host
  rescue StandardError
    nil
  end
end
