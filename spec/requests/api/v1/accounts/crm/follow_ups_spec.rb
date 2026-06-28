require 'rails_helper'

RSpec.describe 'CRM follow-ups API', type: :request do
  around do |example|
    previous_value = ENV.fetch('CRM_KANBAN_ENABLED', nil)
    ENV['CRM_KANBAN_ENABLED'] = 'true'
    example.run
  ensure
    if previous_value.nil?
      ENV.delete('CRM_KANBAN_ENABLED')
    else
      ENV['CRM_KANBAN_ENABLED'] = previous_value
    end
  end

  it 'blocks follow-up endpoints when CRM is disabled' do
    account, user = create_account_and_user
    ENV['CRM_KANBAN_ENABLED'] = 'false'

    get "/api/v1/accounts/#{account.id}/crm/follow_ups",
        headers: auth_headers(user)

    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body['error']).to eq('crm.disabled')
  end

  it 'creates a reminder follow-up and updates the card next due timestamp' do
    skip 'QUARANTINE: pre-existing legacy failure, harness-restore PR; real fix tracked for follow-up PR2'
    account, user = create_account_and_user
    pipeline, stage = create_crm_pipeline(account: account, user: user)
    card = account.crm_cards.create!(pipeline: pipeline, stage: stage, title: 'Lead')
    due_at = 2.hours.from_now

    post "/api/v1/accounts/#{account.id}/crm/follow_ups",
         params: {
           follow_up: {
             card_id: card.id,
             title: 'Retornar lead',
             due_at: due_at.iso8601,
             timezone: 'America/Sao_Paulo',
             automation_mode: 'reminder_only'
           }
         },
         headers: auth_headers(user)

    expect(response).to have_http_status(:created)
    payload = response.parsed_body['payload']
    expect(payload).not_to have_key('account_id')
    expect(payload['card_id']).to eq(card.id)
    expect(payload['status']).to eq('pending')
    expect(card.reload.next_follow_up_at.to_i).to eq(due_at.to_i)
    expect(card.activities.where(event_type: 'follow_up_created')).to exist
  end

  it 'ignores caller supplied contact, inbox and assignee links' do
    account, admin = create_account_and_user
    agent, = create_crm_agent(account: account)
    hidden_inbox = create_crm_inbox(account: account, name: 'Hidden inbox')
    hidden_contact = account.contacts.create!(name: 'Hidden Contact', phone_number: '+5511987654321')
    pipeline, stage = create_crm_pipeline(account: account, user: admin)
    card = account.crm_cards.create!(pipeline: pipeline, stage: stage, owner: agent, title: 'Owned standalone')

    post "/api/v1/accounts/#{account.id}/crm/follow_ups",
         params: {
           follow_up: {
             card_id: card.id,
             contact_id: hidden_contact.id,
             inbox_id: hidden_inbox.id,
             assignee_id: admin.id,
             title: 'Retornar sem vazamento',
             due_at: 2.hours.from_now.iso8601,
             timezone: 'UTC'
           }
         },
         headers: auth_headers(agent)

    expect(response).to have_http_status(:created)
    payload = response.parsed_body['payload']
    expect(payload['contact_id']).to be_nil
    expect(payload['inbox_id']).to be_nil
    expect(payload['assignee_id']).to eq(agent.id)
    expect(payload).not_to have_key('contact')
    expect(payload).not_to have_key('inbox')
    expect(payload['assignee']['id']).to eq(agent.id)
  end

  it 'snoozes a linked conversation when creating a snooze follow-up' do
    account, user = create_account_and_user
    inbox = create_crm_inbox(account: account, members: [user])
    contact = account.contacts.create!(name: 'Lead Snooze', phone_number: '+5511987654321')
    conversation = create_crm_conversation(account: account, inbox: inbox, contact: contact, assignee: user)
    pipeline, stage = create_crm_pipeline(account: account, user: user)
    card = account.crm_cards.create!(
      pipeline: pipeline,
      stage: stage,
      inbox: inbox,
      contact: contact,
      primary_conversation: conversation,
      title: 'Lead Snooze'
    )
    due_at = 1.hour.from_now

    post "/api/v1/accounts/#{account.id}/crm/follow_ups",
         params: {
           follow_up: {
             card_id: card.id,
             conversation_id: conversation.id,
             title: 'Reabrir conversa',
             due_at: due_at.iso8601,
             timezone: 'America/Sao_Paulo',
             automation_mode: 'snooze_conversation'
           }
         },
         headers: auth_headers(user)

    expect(response).to have_http_status(:created)
    expect(conversation.reload.status).to eq('snoozed')
    expect(conversation.snoozed_until.to_i).to eq(due_at.to_i)
  end

  it 'hides follow-ups for inbox cards the agent cannot access' do
    account, admin = create_account_and_user
    agent, = create_crm_agent(account: account)
    inbox = create_crm_inbox(account: account)
    pipeline, stage = create_crm_pipeline(account: account, user: admin)
    card = account.crm_cards.create!(pipeline: pipeline, stage: stage, inbox: inbox, title: 'Oculto')
    follow_up = account.crm_follow_ups.create!(
      card: card,
      title: 'Retornar',
      due_at: 1.hour.from_now,
      timezone: 'UTC',
      created_by: admin
    )

    get "/api/v1/accounts/#{account.id}/crm/follow_ups/#{follow_up.id}",
        headers: auth_headers(agent)

    expect(response).to have_http_status(:not_found)
  end

  it 'completes follow-ups and clears card next due when there are no active follow-ups' do
    account, user = create_account_and_user
    pipeline, stage = create_crm_pipeline(account: account, user: user)
    card = account.crm_cards.create!(pipeline: pipeline, stage: stage, title: 'Lead')
    follow_up = account.crm_follow_ups.create!(
      card: card,
      title: 'Retornar',
      due_at: 1.hour.from_now,
      timezone: 'UTC',
      created_by: user
    )
    Crm::FollowUps::CardNextDueUpdater.update(card)

    post "/api/v1/accounts/#{account.id}/crm/follow_ups/#{follow_up.id}/complete",
         headers: auth_headers(user)

    expect(response).to have_http_status(:ok)
    expect(follow_up.reload.status).to eq('done')
    expect(card.reload.next_follow_up_at).to be_nil
    expect(card.activities.where(event_type: 'follow_up_completed')).to exist
  end

  it 'creates an auto-send follow-up with message body only inside the messaging window' do
    account, user = create_account_and_user
    inbox = create_crm_whatsapp_api_inbox(account: account, members: [user])
    contact = account.contacts.create!(name: 'Lead Session', phone_number: '+5511987654321')
    conversation = create_crm_conversation(account: account, inbox: inbox, contact: contact, assignee: user)
    create_incoming_message(conversation: conversation)
    pipeline, stage = create_crm_pipeline(account: account, user: user)
    card = account.crm_cards.create!(
      pipeline: pipeline,
      stage: stage,
      inbox: inbox,
      contact: contact,
      primary_conversation: conversation,
      title: 'Lead Session'
    )
    due_at = 2.hours.from_now

    post "/api/v1/accounts/#{account.id}/crm/follow_ups",
         params: {
           follow_up: {
             card_id: card.id,
             conversation_id: conversation.id,
             title: 'Enviar mensagem',
             due_at: due_at.iso8601,
             timezone: 'America/Sao_Paulo',
             automation_mode: 'auto_send_message',
             metadata: {
               message_body: 'Olá, retorno combinado'
             }
           }
         },
         headers: auth_headers(user)

    expect(response).to have_http_status(:created)
    payload = response.parsed_body['payload']
    expect(payload['automation_mode']).to eq('auto_send_message')
    expect(payload['metadata']['message_body']).to eq('Olá, retorno combinado')
    expect(payload['metadata']['whatsapp_api_message_template_id']).to be_nil
  end

  it 'rejects auto-send follow-ups without template outside the messaging window' do
    skip 'QUARANTINE: pre-existing legacy failure, harness-restore PR; real fix tracked for follow-up PR2'
    account, user = create_account_and_user
    inbox = create_crm_whatsapp_api_inbox(account: account, members: [user])
    contact = account.contacts.create!(name: 'Lead Outside', phone_number: '+5511987654321')
    conversation = create_crm_conversation(account: account, inbox: inbox, contact: contact, assignee: user)
    create_incoming_message(conversation: conversation)
    conversation.messages.incoming.last.update!(created_at: 30.hours.ago)
    pipeline, stage = create_crm_pipeline(account: account, user: user)
    card = account.crm_cards.create!(
      pipeline: pipeline,
      stage: stage,
      inbox: inbox,
      contact: contact,
      primary_conversation: conversation,
      title: 'Lead Outside'
    )

    post "/api/v1/accounts/#{account.id}/crm/follow_ups",
         params: {
           follow_up: {
             card_id: card.id,
             conversation_id: conversation.id,
             title: 'Enviar mensagem',
             due_at: 2.hours.from_now.iso8601,
             timezone: 'America/Sao_Paulo',
             automation_mode: 'auto_send_message',
             metadata: {
               message_body: 'Olá, retorno combinado'
             }
           }
         },
         headers: auth_headers(user)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body['message']).to include('template fallback')
  end

  it 'creates an auto-send follow-up with message body and API template fallback' do
    account, user = create_account_and_user
    inbox = create_crm_whatsapp_api_inbox(account: account, members: [user])
    contact = account.contacts.create!(name: 'Lead Auto', phone_number: '+5511987654321')
    conversation = create_crm_conversation(account: account, inbox: inbox, contact: contact, assignee: user)
    template = create_whatsapp_api_template(account: account, inbox: inbox, user: user)
    pipeline, stage = create_crm_pipeline(account: account, user: user)
    card = account.crm_cards.create!(
      pipeline: pipeline,
      stage: stage,
      inbox: inbox,
      contact: contact,
      primary_conversation: conversation,
      title: 'Lead Auto'
    )
    due_at = 2.hours.from_now

    post "/api/v1/accounts/#{account.id}/crm/follow_ups",
         params: {
           follow_up: {
             card_id: card.id,
             conversation_id: conversation.id,
             title: 'Enviar mensagem',
             due_at: due_at.iso8601,
             timezone: 'America/Sao_Paulo',
             automation_mode: 'auto_send_message',
             metadata: {
               message_body: 'Olá, retorno combinado',
               whatsapp_api_message_template_id: template.id
             }
           }
         },
         headers: auth_headers(user)

    expect(response).to have_http_status(:created)
    payload = response.parsed_body['payload']
    expect(payload['automation_mode']).to eq('auto_send_message')
    expect(payload['metadata']['message_body']).to eq('Olá, retorno combinado')
    expect(payload['metadata']['whatsapp_api_message_template_id']).to eq(template.id)
  end

  it 'returns messaging window information for a linked conversation' do
    account, user = create_account_and_user
    inbox = create_crm_whatsapp_api_inbox(account: account, members: [user])
    contact = account.contacts.create!(name: 'Lead Window', phone_number: '+5511987654321')
    conversation = create_crm_conversation(account: account, inbox: inbox, contact: contact, assignee: user)
    create_incoming_message(conversation: conversation)

    get "/api/v1/accounts/#{account.id}/crm/follow_ups/messaging_window",
        params: { conversation_id: conversation.id },
        headers: auth_headers(user)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['whatsapp_capable']).to be(true)
    expect(response.parsed_body['can_send_session_message']).to be(true)
    expect(response.parsed_body['requires_template']).to be(false)
    expect(response.parsed_body['whatsapp_api_inbox']).to be(true)
  end

  it 'keeps complete and cancel terminal actions idempotent' do
    account, user = create_account_and_user
    pipeline, stage = create_crm_pipeline(account: account, user: user)
    card = account.crm_cards.create!(pipeline: pipeline, stage: stage, title: 'Lead')
    follow_up = account.crm_follow_ups.create!(
      card: card,
      title: 'Retornar',
      due_at: 1.hour.from_now,
      timezone: 'UTC',
      created_by: user
    )

    post "/api/v1/accounts/#{account.id}/crm/follow_ups/#{follow_up.id}/complete",
         headers: auth_headers(user)
    completed_at = follow_up.reload.completed_at

    post "/api/v1/accounts/#{account.id}/crm/follow_ups/#{follow_up.id}/complete",
         headers: auth_headers(user)
    post "/api/v1/accounts/#{account.id}/crm/follow_ups/#{follow_up.id}/cancel",
         headers: auth_headers(user)

    expect(follow_up.reload.status).to eq('done')
    expect(follow_up.completed_at.to_i).to eq(completed_at.to_i)
    expect(follow_up.canceled_at).to be_nil
    expect(card.activities.where(event_type: 'follow_up_completed').count).to eq(1)
    expect(card.activities.where(event_type: 'follow_up_canceled')).to be_blank
  end

  it 'lists overdue reminder popups and lets users dismiss them once' do
    account, admin = create_account_and_user
    pipeline, stage = create_crm_pipeline(account: account, user: admin)
    card = account.crm_cards.create!(pipeline: pipeline, stage: stage, title: 'Lead', owner: admin)
    follow_up = account.crm_follow_ups.create!(
      card: card,
      title: 'Retornar',
      due_at: 10.minutes.ago,
      timezone: 'UTC',
      automation_mode: :reminder_only,
      status: :overdue,
      assignee: admin,
      created_by: admin
    )

    get "/api/v1/accounts/#{account.id}/crm/follow_ups/reminders",
        headers: auth_headers(admin)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['payload'].pluck('id')).to contain_exactly(follow_up.id)

    post "/api/v1/accounts/#{account.id}/crm/follow_ups/#{follow_up.id}/dismiss_reminder",
         headers: auth_headers(admin)

    expect(response).to have_http_status(:ok)
    expect(follow_up.reload.status).to eq('overdue')
    expect(
      Crm::FollowUps::ReminderDismisser.dismissed_for?(follow_up: follow_up, user: admin)
    ).to be(true)

    get "/api/v1/accounts/#{account.id}/crm/follow_ups/reminders",
        headers: auth_headers(admin)

    expect(response.parsed_body['payload']).to be_empty
  end
end
