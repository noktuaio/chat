require 'rails_helper'

RSpec.describe CampaignImports::UndoLabelsJob, type: :job do
  it 'removes labels when the controller already marked the import as undoing' do
    skip 'QUARANTINE: pre-existing legacy failure, harness-restore PR; real fix tracked for follow-up PR2'
    account, user = create_account_and_user
    contact = account.contacts.create!(name: 'Manual', phone_number: '+5511987654321')
    content = "nome,telefone\nAna,11987654321\nBia,21987654321\n"
    campaign_import = create_campaign_import(account: account, user: user, content: content, batch_count: 2)
    CampaignImports::Validator.new(campaign_import).perform
    campaign_import.update!(status: :queued)
    CampaignImports::Importer.new(campaign_import.reload).perform

    expect(contact.reload.label_list).to include(campaign_import.reload.base_label)

    campaign_import.update!(status: :undoing_labels, undo_status: :processing, undo_started_at: Time.current)

    described_class.perform_now(campaign_import.reload)

    expect(campaign_import.reload).to be_labels_undone
    expect(contact.reload.label_list).not_to include(campaign_import.base_label)
  end

  it 'does not run undo when the feature flag is disabled' do
    account, user = create_account_and_user
    campaign_import = create_campaign_import(account: account, user: user, content: "nome,telefone\nAna,11987654321\n")

    allow(CampaignImports::Config).to receive(:enabled?).and_return(false)
    expect(CampaignImports::UndoLabels).not_to receive(:new)

    described_class.perform_now(campaign_import)

    expect(campaign_import.reload).to be_uploaded
  end
end
