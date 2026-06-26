require 'rails_helper'

describe ChatwootHub do
  describe '.base_url' do
    it 'uses the static hub url' do
      expect(described_class::DEFAULT_BASE_URL).to eq('https://hub.2.chatwoot.com')
      expect(described_class.base_url).to eq('https://hub.2.chatwoot.com')
    end
  end

  it 'generates installation identifier' do
    installation_identifier = described_class.installation_identifier
    expect(installation_identifier).not_to be_nil
    expect(described_class.installation_identifier).to eq installation_identifier
  end

  describe '.pricing_plan_quantity' do
    before do
      allow(ChatwootApp).to receive(:enterprise?).and_return(true)
      allow(ChatwootApp).to receive(:self_hosted_enterprise_configured?).and_return(false)
    end

    it 'returns the installation config value as an integer' do
      create(:installation_config, name: 'INSTALLATION_PRICING_PLAN_QUANTITY', value: '999')

      expect(described_class.pricing_plan_quantity).to eq(999)
    end

    it 'returns zero when the installation config is not present' do
      expect(described_class.pricing_plan_quantity).to eq(0)
    end

    it 'uses the self-hosted enterprise environment quantity when configured' do
      allow(ChatwootApp).to receive(:self_hosted_enterprise_configured?).and_return(true)

      with_modified_env INSTALLATION_PRICING_PLAN_QUANTITY: '10000' do
        expect(described_class.pricing_plan_quantity).to eq(10_000)
      end
    end
  end

  describe '.pricing_plan' do
    before do
      allow(ChatwootApp).to receive(:enterprise?).and_return(true)
      allow(ChatwootApp).to receive(:self_hosted_enterprise_configured?).and_return(false)
    end

    it 'returns the installation config value' do
      create(:installation_config, name: 'INSTALLATION_PRICING_PLAN', value: 'premium')

      expect(described_class.pricing_plan).to eq('premium')
    end

    it 'uses the self-hosted enterprise environment plan when configured' do
      create(:installation_config, name: 'INSTALLATION_PRICING_PLAN', value: 'community')
      allow(ChatwootApp).to receive(:self_hosted_enterprise_configured?).and_return(true)

      expect(described_class.pricing_plan).to eq('enterprise')
    end
  end

  context 'when fetching sync_with_hub' do
    it 'get latest version from chatwoot hub' do
      version = '1.1.1'
      allow(RestClient).to receive(:post).and_return({ version: version }.to_json)
      expect(described_class.sync_with_hub['version']).to eq version
      expect(RestClient).to have_received(:post).with(described_class.ping_url, described_class.instance_config
        .merge(described_class.instance_metrics).to_json, { content_type: :json, accept: :json })
    end

    it 'will not send instance metrics when telemetry is disabled' do
      version = '1.1.1'
      with_modified_env DISABLE_TELEMETRY: 'true' do
        allow(RestClient).to receive(:post).and_return({ version: version }.to_json)
        expect(described_class.sync_with_hub['version']).to eq version
        expect(RestClient).to have_received(:post).with(described_class.ping_url,
                                                        described_class.instance_config.to_json, { content_type: :json, accept: :json })
      end
    end

    it 'returns nil when chatwoot hub is down' do
      allow(RestClient).to receive(:post).and_raise(ExceptionList::REST_CLIENT_EXCEPTIONS.sample)
      expect(described_class.sync_with_hub).to be_nil
    end
  end

  context 'when register instance' do
    let(:company_name) { 'test' }
    let(:owner_name) { 'test' }
    let(:owner_email) { 'test@test.com' }

    it 'sends info of registration' do
      info = { company_name: company_name, owner_name: owner_name, owner_email: owner_email, subscribed_to_mailers: true }
      allow(RestClient).to receive(:post)
      described_class.register_instance(company_name, owner_name, owner_email)
      expect(RestClient).to have_received(:post).with(described_class.registration_url,
                                                      info.merge(described_class.instance_config).to_json, { content_type: :json, accept: :json })
    end
  end

  context 'when sending events' do
    let(:event_name) { 'sample_event' }
    let(:event_data) { { 'sample_data' => 'sample_data' } }

    it 'will send instance events' do
      info = { event_name: event_name, event_data: event_data }
      allow(RestClient).to receive(:post)
      described_class.emit_event(event_name, event_data)
      expect(RestClient).to have_received(:post).with(described_class.events_url,
                                                      info.merge(described_class.instance_config).to_json, { content_type: :json, accept: :json })
    end

    it 'will not send instance events when telemetry is disabled' do
      with_modified_env DISABLE_TELEMETRY: 'true' do
        info = { event_name: event_name, event_data: event_data }
        allow(RestClient).to receive(:post)
        described_class.emit_event(event_name, event_data)
        expect(RestClient).not_to have_received(:post)
          .with(described_class.events_url,
                info.merge(described_class.instance_config).to_json, { content_type: :json, accept: :json })
      end
    end
  end
end
