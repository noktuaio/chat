# == Schema Information
#
# Table name: custom_roles
#
#  id          :bigint           not null, primary key
#  description :string
#  name        :string
#  permissions :text             default([]), is an Array
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  account_id  :bigint           not null
#
# Indexes
#
#  index_custom_roles_on_account_id  (account_id)
#
#

# Available permissions for custom roles:
# - 'conversation_manage': Can manage all conversations.
# - 'conversation_unassigned_manage': Can manage unassigned conversations and assign to self.
# - 'conversation_participating_manage': Can manage conversations they are participating in (assigned to or a participant).
# - 'contact_manage': Can manage contacts.
# - 'report_manage': Can manage reports.
# - 'knowledge_base_manage': Can manage knowledge base portals.

class CustomRole < ApplicationRecord
  belongs_to :account
  has_many :account_users, dependent: :nullify

  PERMISSIONS = %w[
    conversation_manage
    conversation_unassigned_manage
    conversation_participating_manage
    contact_manage
    report_manage
    knowledge_base_manage
  ].freeze

  validates :name, presence: true
  validates :permissions, inclusion: { in: PERMISSIONS }

  # CustomRole details are embedded into the cached account_user payload via
  # api/v1/models/_account_user.json.jbuilder, so bump that cache key on any
  # change. `dependent: :nullify` updates account_users via update_all (which
  # skips their callbacks), so the deletion is bumped here directly.
  after_update_commit -> { account.update_cache_key('account_user') }
  after_destroy_commit -> { account.update_cache_key('account_user') }
end
