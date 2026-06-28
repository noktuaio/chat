class Crm::Reports::AiUsage < Crm::Reports::BaseReport
  HISTORY_PER_PAGE = 25
  GROUP_BY_OPTIONS = %w[hour day].freeze
  RESOURCE_FEATURES = {
    'Organizar cards' => %w[avaliacao_card],
    'Lembretes de retorno' => %w[follow_up],
    'Criação de e-mail' => %w[email],
    'Resumos' => %w[resumo resumo_reuniao],
    'Assistente de respostas' => %w[copilot agente_resposta],
    'Agendamento' => %w[sugestao_horario convite],
    'Mídia' => %w[midia],
    'Base de conhecimento' => %w[kb_revisao kb_instrucao],
    'Construtor de agente' => %w[agente_builder],
    'SLA' => %w[sla]
  }.freeze
  FEATURE_RESOURCES = RESOURCE_FEATURES.each_with_object({}) do |(resource, features), memo|
    features.each { |feature| memo[feature] = resource }
  end.freeze

  def self.resource_for_feature(feature, log_unknown: false)
    FEATURE_RESOURCES[feature.to_s] || unknown_resource(feature, log_unknown: log_unknown)
  end

  def self.unknown_resource(feature, log_unknown:)
    Rails.logger.warn("[crm][ai][usage] unmapped feature=#{feature}") if log_unknown
    'Outros'
  end

  def perform
    {
      account: { id: account.id, name: account.name },
      period: { since: since.iso8601, until: until_time.iso8601, group_by: group_by },
      exchange_rate: exchange_rate_payload,
      totals: totals_payload,
      spend_by_resource: spend_by_resource,
      time_series: time_series,
      history: history_payload
    }
  end

  private

  def usage_scope
    @usage_scope ||= begin
      scope = Crm::AiUsageEvent.for_account(account.id).since(since).where('created_at <= ?', until_time)
      params[:pipeline_id].present? ? scope.where(pipeline_id: params[:pipeline_id]) : scope
    end
  end

  def group_by
    GROUP_BY_OPTIONS.include?(params[:group_by].to_s) ? params[:group_by].to_s : 'day'
  end

  def totals_payload
    count = usage_scope.count
    spend_usd = usage_scope.sum(:cost_estimate)
    savings_usd = cache_savings_usd
    full_cost = spend_usd.to_d + savings_usd

    {
      usage_count: count,
      period_spend: money_payload(spend_usd),
      average_cost: money_payload(count.zero? ? 0 : spend_usd.to_d / count),
      cache_savings: money_payload(savings_usd),
      cache_savings_pct: full_cost.zero? ? 0.0 : percentage(savings_usd / full_cost)
    }
  end

  def spend_by_resource
    grouped = accumulate_resource_totals
    rows = grouped.map { |resource, data| serialize_resource(resource, data) }
    rows.sort_by { |row| -row[:cost_usd] }
  end

  def accumulate_resource_totals
    grouped = Hash.new { |memo, key| memo[key] = empty_resource_totals }
    Crm::AiUsageEvent.spend_by_feature(usage_scope).each do |feature, data|
      resource = self.class.resource_for_feature(feature, log_unknown: true)
      add_feature_totals(grouped[resource], data)
    end
    grouped
  end

  def add_feature_totals(totals, data)
    totals[:usage_count] += data[:calls].to_i
    totals[:input_tokens] += data[:input_tokens].to_i
    totals[:cached_tokens] += data[:cached_tokens].to_i
    totals[:output_tokens] += data[:output_tokens].to_i
    totals[:cost_usd] += data[:cost].to_d
  end

  def serialize_resource(resource, data)
    data.except(:cost_usd).merge(resource: resource).merge(money_payload(data[:cost_usd]))
  end

  def time_series
    usage_scope.group(bucket_expression).sum(:cost_estimate).sort_by { |bucket, _cost_usd| bucket.to_s }.map do |bucket, cost_usd|
      { timestamp: bucket_timestamp(bucket) }.merge(money_payload(cost_usd))
    end
  end

  def history_payload
    paginated = history_scope.page(page).per(HISTORY_PER_PAGE)
    {
      page: page,
      per_page: HISTORY_PER_PAGE,
      total_count: paginated.total_count,
      rows: paginated.map { |event| history_row(event) }
    }
  end

  def history_row(event)
    {
      id: event.id,
      created_at: event.created_at.iso8601,
      resource: self.class.resource_for_feature(event.feature),
      account: { id: account.id, name: account.name },
      input_tokens: event.input_tokens,
      cached_tokens: event.cached_tokens,
      output_tokens: event.output_tokens,
      total_tokens: event.input_tokens.to_i + event.output_tokens.to_i
    }.merge(money_payload(event.cost_estimate))
  end

  def history_scope
    usage_scope
      .select(:id, :feature, :input_tokens, :cached_tokens, :output_tokens, :cost_estimate, :created_at, :pipeline_id)
      .order(created_at: :desc, id: :desc)
  end

  def page
    @page ||= [params[:page].to_i, 1].max
  end

  def bucket_expression
    Arel.sql("date_trunc('#{group_by}', crm_ai_usage_events.created_at)")
  end

  def bucket_timestamp(bucket)
    case bucket
    when Time
      bucket.utc.iso8601
    when DateTime
      bucket.to_time.utc.iso8601
    else
      Time.zone.parse(bucket.to_s).utc.iso8601
    end
  end

  def cache_savings_usd
    usage_scope.group(:model).sum(:cached_tokens).sum do |model, cached_tokens|
      rate = Crm::Ai::Pricing.rate(model)
      discounted = [rate[:input].to_d - rate[:cached].to_d, 0.to_d].max
      (cached_tokens.to_i * discounted) / 1_000_000.to_d
    end
  end

  def exchange_rate
    @exchange_rate ||= Crm::Ai::ExchangeRate.current
  end

  def exchange_rate_payload
    {
      pair: 'USD-BRL',
      rate: exchange_rate[:rate]&.to_d&.round(6)&.to_f,
      fetched_at: exchange_rate[:fetched_at],
      rate_unavailable: exchange_rate[:rate_unavailable] == true
    }
  end

  def money_payload(cost_usd)
    usd = cost_usd.to_d
    payload = { cost_usd: decimal(usd) }
    payload[:cost_brl] = exchange_rate[:rate].present? ? decimal(usd * exchange_rate[:rate].to_d) : nil
    payload[:rate_unavailable] = true if exchange_rate[:rate_unavailable] == true
    payload
  end

  def decimal(value)
    value.to_d.round(6).to_f
  end

  def percentage(value)
    (value.to_d * 100).round(2).to_f
  end

  def empty_resource_totals
    {
      usage_count: 0,
      input_tokens: 0,
      cached_tokens: 0,
      output_tokens: 0,
      cost_usd: 0.to_d
    }
  end
end
