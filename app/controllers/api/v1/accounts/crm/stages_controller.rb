class Api::V1::Accounts::Crm::StagesController < Api::V1::Accounts::Crm::BaseController
  before_action :fetch_pipeline, only: [:index, :create]
  before_action :fetch_stage, only: [:update, :destroy]

  def index
    authorize ::Crm::PipelineStage
    @stages = @pipeline.stages.order(:position, :id)
    @stages_count = @stages.count
  end

  def create
    @stage = Current.account.crm_pipeline_stages.new(stage_params.merge(pipeline: @pipeline))
    apply_default_ai_criteria!(@stage)
    authorize @stage
    @stage.save!
    render :show, status: :created
  end

  def update
    @stage.update!(stage_params)
    render :show
  end

  def destroy
    case Crm::PipelineStages::Destroyer.new(stage: @stage).perform
    when Crm::PipelineStages::Destroyer::HAS_CARDS
      render_unprocessable('crm.stage_has_cards')
    when Crm::PipelineStages::Destroyer::LAST_STAGE
      render_unprocessable('crm.stage_is_last')
    else
      head :no_content
    end
  end

  def reorder
    authorize ::Crm::PipelineStage, :reorder?
    return render_unprocessable('crm.invalid_stage_reorder') unless stage_reorderer.perform == Crm::PipelineStages::Reorderer::SUCCESS

    head :ok
  end

  private

  def fetch_pipeline
    @pipeline = policy_scope(::Crm::Pipeline).find(params[:pipeline_id])
  end

  def fetch_stage
    @stage = policy_scope(::Crm::PipelineStage).find(params[:id])
    authorize @stage
  end

  def stage_params
    parameter_set(:stage).permit(
      :name, :description, :color, :position, :win_probability, :wip_limit,
      :sla_seconds, :sla_warning_seconds, :is_won_stage, :is_lost_stage, metadata: {}
    )
  end

  def stage_reorderer
    Crm::PipelineStages::Reorderer.new(account: Current.account, stage_ids: params[:stage_ids])
  end

  def apply_default_ai_criteria!(stage)
    return if Crm::Ai::Config.stage_ai_criteria(stage).present?

    defaults = Crm::Ai::DefaultStageCriteria.metadata_for(stage.name)
    return if defaults.blank?

    stage.metadata = (stage.metadata || {}).merge(defaults)
  end
end
