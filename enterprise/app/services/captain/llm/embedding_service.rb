class Captain::Llm::EmbeddingService
  include Integrations::LlmInstrumentation

  class EmbeddingsError < StandardError; end

  def initialize(account_id: nil)
    Llm::Config.initialize!
    @account_id = account_id
    @embedding_model = InstallationConfig.find_by(name: 'CAPTAIN_EMBEDDING_MODEL')&.value.presence || LlmConstants::DEFAULT_EMBEDDING_MODEL
  end

  def self.embedding_model
    InstallationConfig.find_by(name: 'CAPTAIN_EMBEDDING_MODEL')&.value.presence || LlmConstants::DEFAULT_EMBEDDING_MODEL
  end

  def get_embedding(content, model: @embedding_model)
    return [] if content.blank?

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    instrument_embedding_call(instrumentation_params(content, model)) do
      RubyLLM.embed(content, model: model).vectors
    end
  rescue RubyLLM::Error => e
    log_failure(e, model: model, started_at: started_at)
    raise EmbeddingsError, "Failed to create an embedding: #{e.message}"
  end

  private

  def log_failure(error, model:, started_at:)
    latency = started_at ? ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round : nil
    Rails.logger.error(
      "[crm][ai][openai_error] operation=captain.embedding model=#{model} error_type=#{error.class.name} " \
      "account_id=#{@account_id} latency_ms=#{latency} message=#{error.message.to_s.truncate(300)}"
    )
  end

  def instrumentation_params(content, model)
    {
      span_name: 'llm.captain.embedding',
      model: model,
      input: content,
      feature_name: 'embedding',
      account_id: @account_id
    }
  end
end
