class V2::Reports::DrilldownRecordSerializer
  MESSAGE_EVENT_METRICS = %w[avg_first_response_time reply_time].freeze

  pattr_initialize :account, :metric, :use_business_hours

  def serialize(record)
    return serialize_message(record) if record.is_a?(Message)
    return serialize_conversation_event(record) if record.is_a?(ReportingEvent)

    serialize_conversation(record)
  end

  private

  def serialize_message(message, metric_value: nil, occurred_at: nil)
    {
      record_type: 'message',
      conversation: conversation_attributes(message.conversation),
      message: message_attributes(message),
      metric_value: metric_value,
      occurred_at: (occurred_at || message.created_at).to_i
    }
  end

  def serialize_conversation_event(event)
    inferred_message = inferred_message_for(event)
    if inferred_message.present?
      return serialize_message(
        inferred_message,
        metric_value: event_metric_value(event),
        occurred_at: event_timestamp(event)
      )
    end

    serialize_conversation(
      event.conversation,
      metric_value: event_metric_value(event),
      occurred_at: event_timestamp(event)
    )
  end

  def serialize_conversation(conversation, metric_value: nil, occurred_at: nil)
    {
      record_type: 'conversation',
      conversation: conversation_attributes(conversation),
      message: nil,
      metric_value: metric_value,
      occurred_at: (occurred_at || conversation&.created_at)&.to_i
    }
  end

  def conversation_attributes(conversation)
    return {} if conversation.blank?

    {
      id: conversation.id,
      display_id: conversation.display_id,
      contact_id: conversation.contact_id,
      contact_name: conversation.contact&.name,
      inbox_id: conversation.inbox_id,
      inbox_name: conversation.inbox&.name,
      assignee_id: conversation.assignee_id,
      assignee_name: conversation.assignee&.name,
      status: conversation.status,
      created_at: conversation.created_at.to_i,
      last_activity_at: conversation.last_activity_at.to_i,
      last_message: last_message_attributes(conversation)
    }
  end

  def message_attributes(message)
    {
      id: message.id,
      content: message.content,
      message_type: message.message_type,
      sender_name: message.sender&.try(:name),
      created_at: message.created_at.to_i
    }
  end

  def last_message_attributes(conversation)
    message = conversation.messages
                          .where(account_id: account.id)
                          .non_activity_messages
                          .first
    return if message.blank?

    message_attributes(message)
  end

  def inferred_message_for(event)
    return unless MESSAGE_EVENT_METRICS.include?(metric)
    return if event.conversation.blank? || event.event_end_time.blank?

    messages = event.conversation.messages
                    .where(account_id: account.id)
                    .where(created_at: message_inference_range(event))
                    .where(message_type: %i[outgoing template])
    messages = messages.where(sender_id: event.user_id, sender_type: 'User') if first_response_event_with_user?(event)

    messages.reorder(created_at: :desc).first
  end

  def first_response_event_with_user?(event)
    metric == 'avg_first_response_time' && event.user_id.present?
  end

  def message_inference_range(event)
    (event.event_end_time - 1.second)..(event.event_end_time + 1.second)
  end

  def event_metric_value(event)
    use_business_hours ? event.value_in_business_hours : event.value
  end

  def event_timestamp(event)
    event.event_end_time || event.created_at
  end
end
