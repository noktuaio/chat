require 'rails_helper'

RSpec.describe Crm::Ai::ExchangeRateRefreshJob, type: :job do
  it 'refreshes the USD to BRL cache' do
    allow(Crm::Ai::ExchangeRate).to receive(:refresh!)

    described_class.perform_now

    expect(Crm::Ai::ExchangeRate).to have_received(:refresh!)
  end

  it 'populates the current exchange rate cache' do
    cache = ActiveSupport::Cache::MemoryStore.new
    allow(Rails).to receive(:cache).and_return(cache)
    stub_request(:get, Crm::Ai::ExchangeRate::API_URL)
      .to_return(status: 200, body: { USDBRL: { bid: '5.4321', timestamp: '1782662400' } }.to_json)

    described_class.perform_now

    expect(Crm::Ai::ExchangeRate.current[:rate]).to eq(BigDecimal('5.4321'))
  end
end
