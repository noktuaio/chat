conversation_visibility = local_assigns[:conversation_visibility] || Crm::Conversations::Visibility.new(
  account: Current.account,
  user: Current.user,
  account_user: Current.account_user
)
conversation_visible = follow_up.conversation.blank? || conversation_visibility.visible?(follow_up.conversation)

safe_contact = follow_up.contact if [follow_up.card&.contact_id, follow_up.conversation&.contact_id].include?(follow_up.contact_id)
safe_inbox = follow_up.inbox if [follow_up.card&.inbox_id, follow_up.conversation&.inbox_id].include?(follow_up.inbox_id)
safe_assignee = follow_up.assignee if [follow_up.card&.owner_id, follow_up.conversation&.assignee_id].include?(follow_up.assignee_id)
safe_assignee ||= follow_up.assignee if Current.account_user&.administrator?

json.extract! follow_up, :id, :account_id, :card_id, :title, :description, :follow_up_type, :status, :automation_mode,
              :timezone, :metadata
json.contact_id safe_contact&.id
json.inbox_id safe_inbox&.id
json.assignee_id safe_assignee&.id
json.conversation_id conversation_visible ? follow_up.conversation_id : nil
json.due_at follow_up.due_at&.iso8601
json.completed_at follow_up.completed_at&.iso8601
json.canceled_at follow_up.canceled_at&.iso8601
json.created_at follow_up.created_at&.iso8601
json.updated_at follow_up.updated_at&.iso8601

if follow_up.card.present?
  json.card do
    json.id follow_up.card.id
    json.title follow_up.card.title
    json.pipeline_id follow_up.card.pipeline_id
    json.stage_id follow_up.card.stage_id
  end
end

if safe_contact.present?
  json.contact do
    json.id safe_contact.id
    json.name safe_contact.name
    json.phone_number safe_contact.phone_number
    json.email safe_contact.email
  end
end

if safe_inbox.present?
  json.inbox do
    json.id safe_inbox.id
    json.name safe_inbox.name
    json.channel_type safe_inbox.channel_type
  end
end

if safe_assignee.present?
  json.assignee do
    json.id safe_assignee.id
    json.name safe_assignee.name
    json.email safe_assignee.email
  end
end

if follow_up.created_by.present?
  json.created_by do
    json.id follow_up.created_by.id
    json.name follow_up.created_by.name
  end
end
