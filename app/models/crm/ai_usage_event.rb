# == Schema Information
#
# Table name: crm_ai_usage_events
#
#  id               :bigint           not null, primary key
#  cached_tokens    :integer          default(0), not null
#  cost_estimate    :decimal(12, 6)   default(0.0), not null
#  feature          :string           not null
#  input_tokens     :integer          default(0), not null
#  latency_ms       :integer
#  model            :string           not null
#  output_tokens    :integer          default(0), not null
#  reasoning_effort :string
#  created_at       :datetime         not null
#  account_id       :bigint           not null
#  pipeline_id      :bigint
#
# Indexes
#
#  idx_crm_ai_usage_account_created          (account_id,created_at)
#  idx_crm_ai_usage_account_feature_created  (account_id,feature,created_at)
#
class Crm::AiUsageEvent < ApplicationRecord
  self.table_name = 'crm_ai_usage_events'

  # Append-only telemetria de consumo de IA. NUNCA guarda prompt/instrução/resposta —
  # só metadados de uso (feature, modelo, tokens, custo, latência) p/ o dashboard Gestão IA.
  belongs_to :account

  after_create_commit :broadcast_usage_created

  validates :feature, presence: true
  validates :model, presence: true

  scope :since, ->(time) { where('created_at >= ?', time) }
  scope :for_account, ->(account_id) { where(account_id: account_id) }

  # Agrega gasto por feature numa janela: { feature => { calls:, cost:, ...tokens } }.
  # Modelo é usado internamente para preço/economia, mas nunca é serializado no dashboard/export.
  def self.spend_by_feature(scope = all)
    grouped = scope.group(:feature)
    calls = grouped.count
    cost = grouped.sum(:cost_estimate)
    input = grouped.sum(:input_tokens)
    cached = grouped.sum(:cached_tokens)
    output = grouped.sum(:output_tokens)
    calls.keys.index_with do |feature|
      {
        calls: calls[feature],
        cost: cost[feature] || 0,
        input_tokens: input[feature] || 0,
        cached_tokens: cached[feature] || 0,
        output_tokens: output[feature] || 0
      }
    end
  end

  private

  def broadcast_usage_created
    Crm::Ai::UsageBroadcastJob.perform_later(id)
  end
end
