FactoryBot.define do
  factory :crm_ai_usage_event, class: 'Crm::AiUsageEvent' do
    account
    pipeline_id { nil }

    add_attribute(:feature) { 'agente_resposta' }
    model { 'gpt-5.4-mini' }
    input_tokens { 1000 }
    cached_tokens { 0 }
    output_tokens { 500 }
    cost_estimate { 0.003 }
    latency_ms { 250 }
    created_at { Time.current }
  end
end
