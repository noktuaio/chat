require 'rails_helper'

RSpec.describe Crm::Cards::FilterQuery do
  around do |example|
    previous_value = ENV.fetch('CRM_KANBAN_ENABLED', nil)
    ENV['CRM_KANBAN_ENABLED'] = 'true'
    example.run
  ensure
    if previous_value.nil?
      ENV.delete('CRM_KANBAN_ENABLED')
    else
      ENV['CRM_KANBAN_ENABLED'] = previous_value
    end
  end

  let(:account_and_user) { create_account_and_user }
  let(:account) { account_and_user.first }
  let(:user) { account_and_user.last }

  # status `open` here is the in-funnel deal status, NOT the conversation status.
  def seed_cards
    pipeline, stage = create_crm_pipeline(account: account, user: user)
    {
      open: account.crm_cards.create!(pipeline: pipeline, stage: stage, title: 'Em andamento', status: :open),
      won: account.crm_cards.create!(pipeline: pipeline, stage: stage, title: 'Ganho', status: :won),
      lost: account.crm_cards.create!(pipeline: pipeline, stage: stage, title: 'Perdido', status: :lost),
      archived: account.crm_cards.create!(pipeline: pipeline, stage: stage, title: 'Arquivado', status: :archived),
    }
  end

  def perform(result)
    described_class.new(scope: account.crm_cards, params: { result: result }).perform
  end

  it 'returns only in-funnel (open) cards when result=open' do
    cards = seed_cards
    expect(perform('open')).to contain_exactly(cards[:open])
  end

  it 'returns only won cards when result=won' do
    cards = seed_cards
    expect(perform('won')).to contain_exactly(cards[:won])
  end

  it 'returns only lost cards when result=lost' do
    cards = seed_cards
    expect(perform('lost')).to contain_exactly(cards[:lost])
  end

  it 'returns only archived cards when result=archived' do
    cards = seed_cards
    expect(perform('archived')).to contain_exactly(cards[:archived])
  end

  it 'does not filter by status when result is blank' do
    cards = seed_cards
    expect(perform('')).to match_array(cards.values)
  end

  it 'ignores an unknown result value' do
    cards = seed_cards
    expect(perform('bogus')).to match_array(cards.values)
  end
end
