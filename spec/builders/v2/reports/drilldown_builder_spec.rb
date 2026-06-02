require 'rails_helper'

RSpec.describe V2::Reports::DrilldownBuilder do
  subject(:drilldown) { described_class.new(account, params).build }

  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:current_time) { Time.zone.parse('2026-05-20 12:00') }
  let(:bucket_start) { current_time.beginning_of_day }
  let(:bucket_end) { bucket_start + 1.day }
  let(:metric) { 'conversations_count' }
  let(:params) do
    {
      metric: metric,
      type: filter_type,
      id: filter_id,
      since: bucket_start.to_i.to_s,
      until: bucket_end.to_i.to_s,
      bucket_timestamp: bucket_start.to_i.to_s,
      group_by: 'day',
      timezone_offset: '0',
      business_hours: false
    }
  end
  let(:filter_type) { :account }
  let(:filter_id) { nil }

  before do
    travel_to current_time
  end

  describe '#build' do
    context 'with conversation count metric' do
      it 'returns conversations created in the clicked bucket' do
        conversation = create(
          :conversation,
          account: account,
          inbox: inbox,
          created_at: bucket_start + 2.hours,
          last_activity_at: bucket_start + 4.hours
        )
        last_message = create(
          :message,
          account: account,
          inbox: inbox,
          conversation: conversation,
          message_type: :incoming,
          content: 'Latest customer note',
          created_at: bucket_start + 3.hours
        )
        conversation.update!(last_activity_at: bucket_start + 4.hours)
        create(:conversation, account: account, inbox: inbox, created_at: bucket_start - 1.hour)

        expect(drilldown[:meta]).to include(metric: 'conversations_count', record_type: 'conversation', total_count: 1)
        expect(drilldown[:meta][:bucket]).to eq({ since: bucket_start.to_i, until: bucket_end.to_i })
        expect(drilldown[:payload].first[:conversation][:display_id]).to eq(conversation.display_id)
        expect(drilldown[:payload].first[:conversation][:created_at]).to eq(
          (bucket_start + 2.hours).to_i
        )
        expect(drilldown[:payload].first[:conversation][:last_activity_at]).to eq(
          (bucket_start + 4.hours).to_i
        )
        expect(drilldown[:payload].first[:conversation][:last_message][:id]).to eq(last_message.id)
        expect(drilldown[:payload].first[:conversation][:last_message][:content]).to eq('Latest customer note')
      end

      context 'when filtering by agent' do
        let(:metric) { 'conversations_count' }
        let(:filter_type) { :agent }
        let(:filter_id) { agent.id }
        let(:agent) { create(:user, account: account) }
        let(:other_agent) { create(:user, account: account) }

        it 'returns only conversations assigned to the selected agent' do
          conversation = create(:conversation, account: account, inbox: inbox, assignee: agent, created_at: bucket_start + 2.hours)
          create(:conversation, account: account, inbox: inbox, assignee: other_agent, created_at: bucket_start + 3.hours)

          expect(drilldown[:meta][:total_count]).to eq(1)
          expect(drilldown[:payload].first[:conversation][:id]).to eq(conversation.id)
        end
      end
    end

    context 'with message count metric' do
      let(:metric) { 'incoming_messages_count' }

      it 'returns messages created in the clicked bucket' do
        conversation = create(:conversation, account: account, inbox: inbox)
        message = create(:message, account: account, inbox: inbox, conversation: conversation,
                                   message_type: :incoming, content: 'Need help', created_at: bucket_start + 1.hour)
        create(:message, account: account, inbox: inbox, conversation: conversation,
                         message_type: :outgoing, created_at: bucket_start + 2.hours)

        expect(drilldown[:meta]).to include(record_type: 'message', total_count: 1)
        expect(drilldown[:payload].first[:record_type]).to eq('message')
        expect(drilldown[:payload].first[:message][:id]).to eq(message.id)
        expect(drilldown[:payload].first[:message][:content]).to eq('Need help')
      end
    end

    context 'with first response time metric' do
      let(:metric) { 'avg_first_response_time' }
      let(:agent) { create(:user, account: account) }

      it 'infers the related outgoing message and uses the selected metric value' do
        conversation = create(:conversation, account: account, inbox: inbox)
        message = create(:message, account: account, inbox: inbox, conversation: conversation,
                                   sender: agent, message_type: :outgoing, created_at: bucket_start + 2.hours)
        create(:reporting_event, account: account, inbox: inbox, conversation: conversation, user: agent,
                                 name: 'first_response', value: 120, value_in_business_hours: 45,
                                 created_at: bucket_start + 2.hours, event_end_time: message.created_at)

        params[:business_hours] = true

        expect(drilldown[:meta]).to include(record_type: 'message', total_count: 1)
        expect(drilldown[:payload].first[:record_type]).to eq('message')
        expect(drilldown[:payload].first[:message][:id]).to eq(message.id)
        expect(drilldown[:payload].first[:metric_value]).to eq(45)
      end

      it 'falls back to the conversation when no matching message is found' do
        conversation = create(:conversation, account: account, inbox: inbox)
        create(:reporting_event, account: account, inbox: inbox, conversation: conversation, user: agent,
                                 name: 'first_response', value: 120, created_at: bucket_start + 2.hours,
                                 event_end_time: bucket_start + 2.hours)

        expect(drilldown[:payload].first[:record_type]).to eq('conversation')
        expect(drilldown[:payload].first[:conversation][:id]).to eq(conversation.id)
      end
    end

    context 'with bot handoff count metric' do
      let(:metric) { 'bot_handoffs_count' }

      it 'returns one row per handoff conversation' do
        first_conversation = create(:conversation, account: account, inbox: inbox)
        second_conversation = create(:conversation, account: account, inbox: inbox)

        create(:reporting_event, account: account, inbox: inbox, conversation: first_conversation,
                                 name: 'conversation_bot_handoff', created_at: bucket_start + 1.hour)
        create(:reporting_event, account: account, inbox: inbox, conversation: first_conversation,
                                 name: 'conversation_bot_handoff', created_at: bucket_start + 2.hours)
        create(:reporting_event, account: account, inbox: inbox, conversation: second_conversation,
                                 name: 'conversation_bot_handoff', created_at: bucket_start + 3.hours)

        expect(drilldown[:meta][:total_count]).to eq(2)
        expect(drilldown[:payload].map { |row| row[:conversation][:id] }).to contain_exactly(
          first_conversation.id,
          second_conversation.id
        )
      end
    end
  end
end
