require 'rails_helper'

RSpec.describe Crm::Ai::ExchangeRate do
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }

  before do
    allow(Rails).to receive(:cache).and_return(cache)
  end

  describe '.current' do
    it 'uses the current cache without hitting AwesomeAPI' do
      cache.write(described_class::CURRENT_CACHE_KEY, { rate: BigDecimal('5.12'), fetched_at: '2026-06-28T10:00:00Z' })
      stub_request(:get, described_class::API_URL).to_raise('should not be called')

      result = described_class.current

      expect(result[:rate]).to eq(BigDecimal('5.12'))
      expect(result[:fetched_at]).to eq('2026-06-28T10:00:00Z')
      expect(result[:rate_unavailable]).to be(false)
    end

    it 'falls back to the last cached rate when current cache is missing' do
      cache.write(described_class::LAST_CACHE_KEY, { rate: BigDecimal('5.08'), fetched_at: '2026-06-28T09:00:00Z' })

      result = described_class.current

      expect(result[:rate]).to eq(BigDecimal('5.08'))
      expect(result[:stale]).to be(true)
      expect(result[:rate_unavailable]).to be(false)
    end

    it 'returns rate_unavailable without HTTP when cache is empty' do
      stub_request(:get, described_class::API_URL)
        .to_raise('should not be called')

      result = described_class.current

      expect(result).to eq(rate: nil, rate_unavailable: true)
      expect(cache.read(described_class::CURRENT_CACHE_KEY)).to be_nil
    end

    it 'reads the cache populated by the refresh path' do
      stub_request(:get, described_class::API_URL)
        .to_return(status: 200, body: { USDBRL: { bid: '5.4321', timestamp: '1782662400' } }.to_json)

      described_class.refresh!

      result = described_class.current

      expect(result[:rate]).to eq(BigDecimal('5.4321'))
      expect(result[:rate_unavailable]).to be(false)
      expect(result[:inline]).to be_nil
    end
  end

  describe '.refresh!' do
    it 'fetches AwesomeAPI bid and writes current and last cache keys' do
      travel_to Time.zone.parse('2026-06-28 12:00:00') do
        stub_request(:get, described_class::API_URL)
          .to_return(status: 200, body: { USDBRL: { bid: '5.6789', timestamp: '1782662400' } }.to_json)

        result = described_class.refresh!

        expect(result[:rate]).to eq(BigDecimal('5.6789'))
        expect(result[:rate_unavailable]).to be(false)
        expect(cache.read(described_class::CURRENT_CACHE_KEY)[:rate]).to eq(BigDecimal('5.6789'))
        expect(cache.read(described_class::LAST_CACHE_KEY)[:rate]).to eq(BigDecimal('5.6789'))
        expect(cache.read(described_class::LAST_CACHE_KEY)[:fetched_at]).to eq('2026-06-28T12:00:00Z')
      end
    end
  end
end
