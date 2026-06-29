class Crm::PipelineStages::Destroyer
  SUCCESS = :success
  HAS_CARDS = :has_cards
  LAST_STAGE = :last_stage

  def initialize(stage:)
    @stage = stage
  end

  # An EMPTY stage (no cards of any status) is deletable from the UI. Two things that used to block it
  # are handled here instead of surfacing as a raw FK violation:
  #   - AI suggestion history cascades away (see Crm::PipelineStage associations).
  #   - If the stage is an inbox's default landing stage, the default is reassigned to a surviving
  #     stage so new conversations keep a valid home.
  # Cards (any status) still block: a card must always point at a real stage.
  def perform
    return HAS_CARDS if @stage.cards.exists?
    return LAST_STAGE if fallback_stage.blank?

    ActiveRecord::Base.transaction do
      reassign_default_stage!
      @stage.destroy!
    end
    SUCCESS
  rescue ActiveRecord::InvalidForeignKey
    # Race: a card was attached to the stage between the cards.exists? check and destroy!.
    # A stage that still owns a card cannot be removed — report it as such.
    HAS_CARDS
  end

  private

  def fallback_stage
    @fallback_stage ||= @stage.pipeline.stages.where.not(id: @stage.id).order(:position, :id).first
  end

  # Repoint every place that named this stage as the default landing stage to the fallback, so new
  # conversations/cards keep a valid home. These are logical references (some lack a DB FK), scoped to
  # the stage's own account/pipeline so deleting a stage can never touch another tenant's rows.
  # Bulk FK pointer swap — no validations/callbacks to run, so update_all is intentional.
  def reassign_default_stage!
    account_id = @stage.account_id
    fallback_id = fallback_stage.id
    # rubocop:disable Rails/SkipsModelValidations
    Crm::PipelineInbox.where(account_id: account_id, pipeline_id: @stage.pipeline_id, default_stage_id: @stage.id)
                      .update_all(default_stage_id: fallback_id)
    Crm::InboxSetting.where(account_id: account_id, default_stage_id: @stage.id).update_all(default_stage_id: fallback_id)
    Crm::AgentBookingProfile.where(account_id: account_id, default_stage_id: @stage.id).update_all(default_stage_id: fallback_id)
    # rubocop:enable Rails/SkipsModelValidations
  end
end
