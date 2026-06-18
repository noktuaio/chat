require 'rails_helper'

RSpec.describe 'Autonomia::AuthController', type: :request do
  let(:frontend_url) { 'https://agents.autonomia.site' }
  let(:issuer_url) { 'https://auth.autonomia.site' }
  let(:callback_url) { "#{frontend_url}/auth/autonomia/callback" }
  let(:sso_env) do
    {
      FRONTEND_URL: frontend_url,
      AUTONOMIA_AUTH_ISSUER: issuer_url,
      AUTONOMIA_AUTH_CLIENT_ID: 'talkai',
      AUTONOMIA_AUTH_REDIRECT_URI: callback_url
    }
  end

  describe 'GET /auth/autonomia' do
    it 'redirects to Autonomia Identity with an encrypted state and PKCE challenge' do
      with_modified_env sso_env do
        get '/auth/autonomia'
      end

      redirect = URI.parse(response.location)
      params = Rack::Utils.parse_query(redirect.query)

      expect(redirect.to_s).to start_with("#{issuer_url}/login?")
      expect(params['client_id']).to eq('talkai')
      expect(params['redirect_uri']).to eq(callback_url)
      expect(params['response_type']).to eq('code')
      expect(params['code_challenge']).to be_present
      expect(params['code_challenge_method']).to eq('S256')
      expect(params['state']).to be_present
    end
  end

  describe 'GET /auth/autonomia/callback' do
    let(:code) { SecureRandom.urlsafe_base64(24) }
    let(:user) { create(:user) }
    let(:token) { Autonomia::Sso::Client::Token.new(access_token: 'identity-access-token') }
    let(:client) { instance_double(Autonomia::Sso::Client) }
    let(:provisioner) { instance_double(Autonomia::Sso::Provisioner, perform: user) }

    it 'exchanges the code even when the Rails session cookie was not preserved' do
      with_modified_env sso_env do
        get '/auth/autonomia'
      end

      state = Rack::Utils.parse_query(URI.parse(response.location).query).fetch('state')
      reset!

      allow(Autonomia::Sso::Client).to receive(:new).and_return(client)
      allow(client).to receive(:exchange_code!).and_return(token)
      allow(client).to receive(:fetch_context!).with('identity-access-token').and_return({})
      allow(Autonomia::Sso::Provisioner).to receive(:new).with(context: {}).and_return(provisioner)

      with_modified_env sso_env do
        get '/auth/autonomia/callback', params: { code: code, state: state }
      end

      expect(client).to have_received(:exchange_code!).with(
        code: code,
        redirect_uri: callback_url,
        code_verifier: be_present
      )
      expect(response).to redirect_to(
        %r{\A#{frontend_url}/app/login\?email=#{Regexp.escape(ERB::Util.url_encode(user.email))}&sso_auth_token=}
      )
    end

    it 'rejects an invalid state before exchanging the code' do
      allow(Autonomia::Sso::Client).to receive(:new)

      get '/auth/autonomia/callback', params: { code: code, state: 'invalid-state' }

      expect(Autonomia::Sso::Client).not_to have_received(:new)
      expect(response).to redirect_to(%r{/app/login\?error=autonomia-sso-state$})
    end
  end
end
