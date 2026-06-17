class EnableTiktokForPaidAccounts < ActiveRecord::Migration[7.0]
  PAID_PLAN_NAMES = %w[Startups Business Enterprise].freeze

  def up
    Account.where("custom_attributes ->> 'plan_name' IN (?)", PAID_PLAN_NAMES).find_in_batches(batch_size: 100) do |accounts|
      accounts.each { |account| account.enable_features!('channel_tiktok') }
    end
  end
end
