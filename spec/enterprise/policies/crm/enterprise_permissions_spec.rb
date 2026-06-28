require 'rails_helper'

# CRM granular permissions overlay (Enterprise). Lives under spec/enterprise so
# the FOSS CI run (which strips enterprise/) skips it — the assertions only hold
# when the EE policy overlay is loaded. Covers the plain-agent admin-grade scoping
# (PLAIN_AGENT_DENIED_KEYS) and the custom-role granular gating.
RSpec.describe 'Crm Enterprise permission overlay', type: :policy do # rubocop:disable RSpec/DescribeClass
  def ctx(account, user, account_user)
    { account: account, user: user, account_user: account_user }
  end

  def custom_role_user(account:, permissions:)
    user, account_user = create_crm_agent(account: account, name: 'Custom Role User')
    role = CustomRole.create!(account: account, name: "Role #{SecureRandom.hex(4)}", permissions: permissions)
    account_user.update!(custom_role: role)
    [user, account_user]
  end

  let(:account_and_admin) { create_account_and_user }
  let(:account) { account_and_admin.first }
  let(:admin) { account_and_admin.last }
  let(:pipeline) { create_crm_pipeline(account: account, user: admin).first }

  describe 'EE module wiring (ancestors-include smoke)' do
    it 'prepends EE modules onto OSS CRM policies' do
      expect(Crm::PipelinePolicy.ancestors).to include(Enterprise::Crm::PipelinePolicy)
      expect(Crm::CardPolicy.ancestors).to include(Enterprise::Crm::CardPolicy)
    end
  end

  describe 'plain agents (no custom role)' do
    let(:plain) { create_crm_agent(account: account) }
    let(:context) { ctx(account, plain.first, plain.last) }

    it 'keeps day-to-day access (view + reports)' do
      expect(Crm::PipelinePolicy.new(context, pipeline).index?).to be(true)
      expect(Crm::ReportPolicy.new(ctx(account, plain.first, plain.last), %i[crm report]).view?).to be(true)
    end

    it 'denies admin-grade config (pipelines, automations, AI settings, integration tokens)' do
      expect(Crm::PipelinePolicy.new(context, pipeline).create?).to be(false)
      expect(Crm::PipelinePolicy.new(context, pipeline).update?).to be(false)
      expect(Crm::PipelinePolicy.new(context, pipeline).manage_ai?).to be(false)
      expect(Crm::StageAutomationPolicy.new(context, Crm::StageAutomation).create?).to be(false)
      expect(Crm::IntegrationTokenPolicy.new(context, Crm::IntegrationToken).create?).to be(false)
    end
  end

  describe 'custom-role users (granular gating)' do
    it 'denies everything to a role with no crm_* keys' do
      user, account_user = custom_role_user(account: account, permissions: [])
      policy = Crm::PipelinePolicy.new(ctx(account, user, account_user), pipeline)

      expect(policy.index?).to be(false)
      expect(policy.create?).to be(false)
    end

    it 'grants read but not management to crm_view' do
      user, account_user = custom_role_user(account: account, permissions: ['crm_view'])
      policy = Crm::PipelinePolicy.new(ctx(account, user, account_user), pipeline)

      expect(policy.index?).to be(true)
      expect(policy.create?).to be(false)
    end

    it 'grants pipeline management to crm_manage_pipelines' do
      user, account_user = custom_role_user(account: account, permissions: %w[crm_view crm_manage_pipelines])
      policy = Crm::PipelinePolicy.new(ctx(account, user, account_user), pipeline)

      expect(policy.create?).to be(true)
      expect(policy.update?).to be(true)
    end

    it 'treats crm_admin as full CRM access (incl. integration tokens)' do
      user, account_user = custom_role_user(account: account, permissions: ['crm_admin'])

      expect(Crm::PipelinePolicy.new(ctx(account, user, account_user), pipeline).create?).to be(true)
      expect(Crm::IntegrationTokenPolicy.new(ctx(account, user, account_user), Crm::IntegrationToken).create?).to be(true)
    end

    it 'gates manage_ai? by crm_manage_ai' do
      view_user, view_au = custom_role_user(account: account, permissions: ['crm_view'])
      ai_user, ai_au = custom_role_user(account: account, permissions: %w[crm_view crm_manage_ai])

      expect(Crm::PipelinePolicy.new(ctx(account, view_user, view_au), pipeline).manage_ai?).to be(false)
      expect(Crm::PipelinePolicy.new(ctx(account, ai_user, ai_au), pipeline).manage_ai?).to be(true)
    end
  end

  describe 'administrators' do
    it 'keep full CRM access regardless of custom role' do
      policy = Crm::PipelinePolicy.new(ctx(account, admin, account.account_users.find_by(user_id: admin.id)), pipeline)

      expect(policy.create?).to be(true)
      expect(policy.update?).to be(true)
    end
  end
end
