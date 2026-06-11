class Api::V1::Accounts::OnboardingsController < Api::V1::Accounts::BaseController
  before_action :check_admin_authorization?

  ONBOARDING_STEPS = %w[account_details inbox_setup].freeze

  def update
    return render json: { error: 'Invalid onboarding step' }, status: :unprocessable_entity unless valid_onboarding_step?

    @account = Current.account
    complete_onboarding_step

    render 'api/v1/accounts/update', format: :json
  end

  def help_center_generation
    render json: help_center_generation_status
  end

  private

  # The client declares which step it is completing; step `foo` runs
  # `complete_foo`, which owns persisting that step's data, advancing the cursor,
  # and any side effects. Dispatch is gated on the known-step list so the client
  # value can never `send` an arbitrary method.
  def valid_onboarding_step?
    ONBOARDING_STEPS.include?(params[:onboarding_step])
  end

  def complete_onboarding_step
    send("complete_#{params[:onboarding_step]}")
  end

  def complete_account_details
    # The stored cursor may still be 'enrichment' when the client submits after
    # the enrichment timeout, so accept either pre-inbox_setup state. A stale
    # replay after onboarding finished (no stored step) must not re-enter it.
    return unless %w[enrichment account_details].include?(@account.custom_attributes['onboarding_step'])

    @account.assign_attributes(account_params)
    @account.custom_attributes.merge!(custom_attributes_params)
    @account.custom_attributes['onboarding_step'] = 'inbox_setup'
    @account.save!
    create_onboarding_inboxes
  end

  def complete_inbox_setup
    # Only finalize while the stored cursor still points here, so a stale or
    # out-of-order request can't end onboarding early. Replays are no-ops.
    return unless @account.custom_attributes['onboarding_step'] == 'inbox_setup'

    @account.custom_attributes.delete('onboarding_step')
    @account.save!
  end

  def create_onboarding_inboxes
    Onboarding::WebWidgetCreationService.new(@account, Current.user).perform
  end

  def account_params
    params.permit(:name, :locale)
  end

  def custom_attributes_params
    params.permit(:industry, :company_size, :timezone, :referral_source, :user_role, :website)
  end

  def help_center_generation_status
    {
      generation_id: nil,
      state: nil,
      articles_count: 0,
      categories_count: 0
    }
  end
end

Api::V1::Accounts::OnboardingsController.prepend_mod_with('Api::V1::Accounts::OnboardingsController')
