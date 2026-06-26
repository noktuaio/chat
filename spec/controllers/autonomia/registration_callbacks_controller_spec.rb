# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Autonomia::RegistrationCallbacksController', type: :request do
  let(:frontend_url) { 'https://agents.autonomia.site' }
  let(:user) { create(:user, email: 'admin@autonomia.solutions') }
  let(:account) { create(:account) }
  let(:result) { Autonomia::RegistrationCheckout::Provisioner::Result.new(user: user, account: account) }
  let(:provisioner) { instance_double(Autonomia::RegistrationCheckout::Provisioner, perform: result) }

  describe 'GET /register/callback' do
    it 'provisions the registration checkout callback and redirects through SSO token login' do
      allow(Autonomia::RegistrationCheckout::Provisioner).to receive(:new).and_return(provisioner)

      with_modified_env FRONTEND_URL: frontend_url do
        get '/register/callback',
            params: {
              auth_user_id: 'auth-user-123',
              checkout_status: 'paid',
              client_id: 'talkai',
              email: 'admin@autonomia.solutions'
            }
      end

      expect(Autonomia::RegistrationCheckout::Provisioner).to have_received(:new).with(
        params: hash_including(
          'auth_user_id' => 'auth-user-123',
          'checkout_status' => 'paid',
          'client_id' => 'talkai',
          'email' => 'admin@autonomia.solutions'
        )
      )
      expect(response).to redirect_to(
        %r{\A#{frontend_url}/app/login\?email=#{Regexp.escape(ERB::Util.url_encode(user.email))}&sso_auth_token=}
      )
    end

    it 'redirects to login with an invalid registration error when callback is rejected' do
      allow(Autonomia::RegistrationCheckout::Provisioner).to receive(:new).and_return(provisioner)
      allow(provisioner).to receive(:perform).and_raise(
        Autonomia::RegistrationCheckout::Provisioner::InvalidCallback,
        'Checkout was not completed.'
      )

      with_modified_env FRONTEND_URL: frontend_url do
        get '/register/callback', params: { checkout_status: 'pending' }
      end

      expect(response).to redirect_to("#{frontend_url}/app/login?error=autonomia-registration-invalid")
    end
  end
end
