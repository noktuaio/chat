require 'rails_helper'

RSpec.describe Crm::Ai::Config do
  describe '.handoff_settings' do
    def pipeline_with(metadata)
      OpenStruct.new(metadata: metadata)
    end

    def stage_with(metadata)
      OpenStruct.new(metadata: metadata)
    end

    it 'returns back-compatible defaults for new handoff fields' do
      settings = described_class.handoff_settings(stage_with({}), pipeline_with({}))

      expect(settings[:pool_type]).to eq('inbox')
      expect(settings[:pool_id]).to be_nil
      expect(settings[:selector_mode]).to eq('round_robin')
      expect(settings[:escalation_action]).to eq('renotify')
      expect(settings[:renotify_after_seconds]).to eq(900)
      expect(settings[:pickup_threshold_seconds]).to eq(900)
    end

    it 'aliases selector_mode to effective mode unless explicitly overridden' do
      inherited = described_class.handoff_settings(
        stage_with({}),
        pipeline_with('ai' => { 'handoff' => { 'mode' => 'direct' } })
      )
      overridden = described_class.handoff_settings(
        stage_with({ 'ai_handoff' => { 'mode' => 'direct', 'selector_mode' => 'round_robin' } }),
        pipeline_with({})
      )

      expect(inherited[:mode]).to eq('direct')
      expect(inherited[:selector_mode]).to eq('direct')
      expect(overridden[:mode]).to eq('direct')
      expect(overridden[:selector_mode]).to eq('round_robin')
    end

    it 'parses user pool ids from strings and integers and falls back invalid pool types' do
      string_id = described_class.handoff_settings(
        stage_with({ 'ai_handoff' => { 'pool_type' => 'user', 'pool_id' => '42' } }),
        pipeline_with({})
      )
      integer_id = described_class.handoff_settings(
        stage_with({ 'ai_handoff' => { 'pool_type' => 'user', 'pool_id' => 77 } }),
        pipeline_with({})
      )
      invalid_pool = described_class.handoff_settings(
        stage_with({ 'ai_handoff' => { 'pool_type' => 'team', 'pool_id' => '42' } }),
        pipeline_with({})
      )

      expect(string_id[:pool_type]).to eq('user')
      expect(string_id[:pool_id]).to eq(42)
      expect(integer_id[:pool_type]).to eq('user')
      expect(integer_id[:pool_id]).to eq(77)
      expect(invalid_pool[:pool_type]).to eq('inbox')
    end

    it 'keeps escalation_action escalate when escalation_user_id is present' do
      settings = described_class.handoff_settings(
        stage_with({ 'ai_handoff' => { 'escalation_action' => 'escalate', 'escalation_user_id' => '123' } }),
        pipeline_with({})
      )

      expect(settings[:escalation_user_id]).to eq(123)
      expect(settings[:escalation_action]).to eq('escalate')
    end

    it 'defaults escalation_action to escalate when legacy escalation_user_id is present' do
      settings = described_class.handoff_settings(
        stage_with({ 'ai_handoff' => { 'escalation_user_id' => '123' } }),
        pipeline_with({})
      )

      expect(settings[:escalation_user_id]).to eq(123)
      expect(settings[:escalation_action]).to eq('escalate')
    end

    it 'coerces escalation_action escalate to renotify without escalation_user_id' do
      settings = described_class.handoff_settings(
        stage_with({ 'ai_handoff' => { 'escalation_action' => 'escalate' } }),
        pipeline_with({})
      )

      expect(settings[:escalation_user_id]).to be_nil
      expect(settings[:escalation_action]).to eq('renotify')
    end

    it 'lets stage metadata override pipeline metadata for new fields' do
      settings = described_class.handoff_settings(
        stage_with(
          'ai_handoff' => {
            'selector_mode' => 'round_robin',
            'pool_type' => 'inbox',
            'pool_id' => '22',
            'renotify_after_seconds' => 120,
            'escalation_action' => 'renotify'
          }
        ),
        pipeline_with(
          'ai' => {
            'handoff' => {
              'selector_mode' => 'direct',
              'pool_type' => 'user',
              'pool_id' => '11',
              'renotify_after_seconds' => 60,
              'escalation_action' => 'escalate',
              'escalation_user_id' => '99'
            }
          }
        )
      )

      expect(settings[:selector_mode]).to eq('round_robin')
      expect(settings[:pool_type]).to eq('inbox')
      expect(settings[:pool_id]).to eq(22)
      expect(settings[:renotify_after_seconds]).to eq(120)
      expect(settings[:escalation_action]).to eq('renotify')
    end

    it 'honors custom renotify_after_seconds and falls back to pickup threshold for invalid values' do
      custom = described_class.handoff_settings(
        stage_with({ 'ai_handoff' => { 'pickup_threshold_seconds' => 300, 'renotify_after_seconds' => 45 } }),
        pipeline_with({})
      )
      zero = described_class.handoff_settings(
        stage_with({ 'ai_handoff' => { 'pickup_threshold_seconds' => 300, 'renotify_after_seconds' => 0 } }),
        pipeline_with({})
      )
      garbage = described_class.handoff_settings(
        stage_with({ 'ai_handoff' => { 'pickup_threshold_seconds' => 300, 'renotify_after_seconds' => 'soon' } }),
        pipeline_with({})
      )

      expect(custom[:renotify_after_seconds]).to eq(45)
      expect(zero[:renotify_after_seconds]).to eq(300)
      expect(garbage[:renotify_after_seconds]).to eq(300)
    end
  end
end
