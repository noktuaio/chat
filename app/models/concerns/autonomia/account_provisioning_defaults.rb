# frozen_string_literal: true

module Autonomia::AccountProvisioningDefaults
  extend ActiveSupport::Concern

  DEFAULT_FEATURE_FLAGS = 8_950_126_033_336_532_983
  DEFAULT_ACCOUNT_USER_ID = 1

  included do
    before_create :apply_autonomia_default_feature_flags, if: :autonomia_account_defaults_enabled?
    after_create_commit :ensure_autonomia_default_account_user, if: :autonomia_account_defaults_enabled?
  end

  private

  def apply_autonomia_default_feature_flags
    self.feature_flags = autonomia_default_feature_flags
  end

  def ensure_autonomia_default_account_user
    user = User.find_by(id: autonomia_default_account_user_id)
    return if user.blank?

    AccountUser.find_or_create_by!(account: self, user: user) do |account_user|
      account_user.role = 'administrator'
    end
  end

  def autonomia_default_feature_flags
    ENV.fetch('AUTONOMIA_DEFAULT_ACCOUNT_FEATURE_FLAGS', DEFAULT_FEATURE_FLAGS).to_i
  end

  def autonomia_default_account_user_id
    ENV.fetch('AUTONOMIA_DEFAULT_ACCOUNT_USER_ID', DEFAULT_ACCOUNT_USER_ID).to_i
  end

  def autonomia_account_defaults_enabled?
    value = ENV.fetch('AUTONOMIA_ACCOUNT_DEFAULTS_ENABLED', nil)
    return ActiveModel::Type::Boolean.new.cast(value) unless value.nil?

    !Rails.env.test?
  end
end
