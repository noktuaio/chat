require 'rails_helper'

RSpec.describe Integrations::Cloudflare::RealtimeKitCredentialsValidator do
  let(:account_id) { 'account_id' }
  let(:app_id) { 'app_id' }
  let(:api_token) { 'api_token' }
  let(:token_verify_url) { 'https://api.cloudflare.com/client/v4/user/tokens/verify' }
  let(:apps_url) { "https://api.cloudflare.com/client/v4/accounts/#{account_id}/realtime/kit/apps" }

  it 'accepts an active token with access to the requested RealtimeKit app' do
    stub_token_verify(status: 'active')
    stub_apps_list([{ id: app_id }])

    expect(described_class.valid?(account_id, app_id, api_token)).to be true
    expect(described_class.validate(account_id, app_id, api_token).success?).to be true
  end

  it 'rejects inactive tokens' do
    stub_token_verify(status: 'disabled')

    expect(described_class.valid?(account_id, app_id, api_token)).to be false
    expect(described_class.validate(account_id, app_id, api_token).error).to eq(:invalid_api_token)
  end

  it 'rejects tokens without access to the Cloudflare account' do
    stub_token_verify(status: 'active')
    stub_apps_request.to_return(status: 403, body: { success: false }.to_json)

    expect(described_class.valid?(account_id, app_id, api_token)).to be false
    expect(described_class.validate(account_id, app_id, api_token).error).to eq(:invalid_account_or_permissions)
  end

  it 'rejects a RealtimeKit App ID that is not present in the account' do
    stub_token_verify(status: 'active')
    stub_apps_list([{ id: 'another_app_id' }])

    expect(described_class.valid?(account_id, app_id, api_token)).to be false
    expect(described_class.validate(account_id, app_id, api_token).error).to eq(:app_not_found)
  end

  it 'rejects blank credentials without making a network call' do
    expect(described_class.valid?(nil, app_id, api_token)).to be false
    expect(described_class.valid?(account_id, nil, api_token)).to be false
    expect(described_class.valid?(account_id, app_id, nil)).to be false
    expect(described_class.validate(nil, app_id, api_token).error).to eq(:missing_credentials)
  end

  it 'treats transient Cloudflare failures as valid to avoid blocking saves' do
    stub_request(:get, token_verify_url).to_return(status: 500)
    stub_apps_list([{ id: app_id }])
    expect(described_class.valid?(account_id, app_id, api_token)).to be true

    stub_token_verify(status: 'active')
    stub_apps_request.to_return(status: 500)
    expect(described_class.valid?(account_id, app_id, api_token)).to be true
  end

  def stub_token_verify(status:)
    stub_request(:get, token_verify_url)
      .with(headers: { 'Authorization' => "Bearer #{api_token}" })
      .to_return(status: 200, body: { success: true, result: { status: status } }.to_json)
  end

  def stub_apps_list(apps)
    stub_apps_request
      .to_return(status: 200, body: { success: true, data: apps.map(&:stringify_keys), result_info: { total_count: apps.size } }.to_json)
  end

  def stub_apps_request
    stub_request(:get, apps_url)
      .with(headers: { 'Authorization' => "Bearer #{api_token}" })
  end
end
