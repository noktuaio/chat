require 'rails_helper'

RSpec.describe CustomRole, type: :model do
  describe 'associations' do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to have_many(:account_users).dependent(:nullify) }
  end

  describe 'validations' do
    it { is_expected.to validate_presence_of(:name) }
  end

  describe 'account_user cache invalidation' do
    let(:custom_role) { create(:custom_role) }

    it 'bumps the account_user cache key after update' do
      expect(custom_role.account).to receive(:update_cache_key).with('account_user')
      custom_role.update(name: 'New Name')
    end

    it 'bumps the account_user cache key after destroy' do
      custom_role
      expect(custom_role.account).to receive(:update_cache_key).with('account_user')
      custom_role.destroy
    end
  end
end
