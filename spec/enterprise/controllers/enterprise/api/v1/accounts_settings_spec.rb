# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Enterprise::Api::V1::AccountsSettings do
  let(:account) { create(:account) }
  let(:cookies) { {} }
  let(:controller) { test_controller.new(account, cookies) }

  before do
    allow(ChatwootApp).to receive(:chatwoot_cloud?).and_return(true)
  end

  it 'stores website attribution cookies on the account' do
    cookies[described_class::FIRST_TOUCH_COOKIE] = encoded_cookie(
      'source' => 'reddit',
      'source_type' => 'paid_social',
      'referrer' => 'https://reddit.com',
      'referrer_path' => '/r/selfhosted/comments/123/chatwoot'
    )
    cookies[described_class::LAST_TOUCH_COOKIE] = encoded_cookie(
      'source' => 'github',
      'source_type' => 'referral'
    )

    controller.create

    attribution = account.reload.internal_attributes['marketing_attribution']
    expect(attribution['captured_from']).to eq('cookie')
    expect(attribution['first_touch']['source']).to eq('reddit')
    expect(attribution['first_touch']['referrer_path']).to eq('/r/selfhosted/comments/123/chatwoot')
    expect(attribution['last_touch']['source']).to eq('github')
  end

  it 'does not store attribution outside Chatwoot Cloud' do
    allow(ChatwootApp).to receive(:chatwoot_cloud?).and_return(false)
    cookies[described_class::LAST_TOUCH_COOKIE] = encoded_cookie('source' => 'reddit')

    controller.create

    expect(account.reload.internal_attributes).not_to include('marketing_attribution')
  end

  def encoded_cookie(payload)
    CGI.escape(payload.to_json)
  end

  def test_controller
    Class.new do
      prepend Enterprise::Api::V1::AccountsSettings

      attr_reader :cookies

      def initialize(account, cookies)
        @account = account
        @cookies = cookies
      end

      def create; end
    end
  end
end
