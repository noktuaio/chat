require 'rails_helper'

RSpec.describe Crm::Ai::Pricing do
  describe '.rate' do
    it 'returns zero rate for an unknown model with no ENV override' do
      expect(described_class.rate('modelo-inexistente')).to eq(input: 0.0, cached: 0.0, output: 0.0)
    end

    it 'returns the OpenAI table rate for the default known models' do
      expect(described_class.rate('gpt-5.4')).to eq(input: 2.5, cached: 0.25, output: 15.0)
      expect(described_class.rate('gpt-5.4-mini')).to eq(input: 0.75, cached: 0.075, output: 4.5)
    end

    it 'reads an ENV override normalizing the model into the price var name' do
      ClimateControl.modify(CRM_AI_PRICE_GPT_5_4_MINI: '0.15,0.015,0.6') do
        expect(described_class.rate('gpt-5.4-mini')).to eq(input: 0.15, cached: 0.015, output: 0.6)
      end
    end

    it 'normalizes every non-alphanumeric char in the model to underscore' do
      ClimateControl.modify(CRM_AI_PRICE_GPT_5_4: '2.5,0.25,10') do
        expect(described_class.rate('gpt-5.4')).to eq(input: 2.5, cached: 0.25, output: 10.0)
      end
    end
  end

  describe '.cost' do
    it 'is zero for an unknown model with no ENV override' do
      expect(described_class.cost(model: 'modelo-inexistente', input_tokens: 1000, output_tokens: 500)).to eq(0.0)
    end

    it 'uses the default table rate for a known model' do
      # gpt-5.4: input 2.5, cached 0.25, output 15 (USD/1M)
      # (1000*2.5 + 500*15) / 1_000_000 = 10000 / 1_000_000
      cost = described_class.cost(model: 'gpt-5.4', input_tokens: 1000, output_tokens: 500)
      expect(cost).to be_within(1e-9).of(0.01)
    end

    it 'charges cached tokens at the discounted rate and the remaining input at full rate' do
      ClimateControl.modify(CRM_AI_PRICE_GPT_5_4: '2.5,0.25,10') do
        # input=1000 inclui 200 cacheados -> billable_input = 800
        # (800*2.5 + 200*0.25 + 500*10) / 1_000_000 = 7050 / 1_000_000
        cost = described_class.cost(model: 'gpt-5.4', input_tokens: 1000, cached_tokens: 200, output_tokens: 500)
        expect(cost).to be_within(1e-9).of(0.00705)
      end
    end

    it 'never lets billable input go negative when cached exceeds input' do
      ClimateControl.modify(CRM_AI_PRICE_GPT_5_4: '2.5,0.25,10') do
        cost = described_class.cost(model: 'gpt-5.4', input_tokens: 100, cached_tokens: 500, output_tokens: 0)
        # billable_input clamped a 0 -> só os 500 cacheados a 0.25
        expect(cost).to be_within(1e-9).of(500 * 0.25 / 1_000_000.0)
      end
    end
  end
end
