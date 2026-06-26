module Enterprise::Api::V1::Accounts::AgentsController
  def create
    super
    associate_agent_with_custom_role
  end

  def update
    super
    associate_agent_with_custom_role
  end

  private

  def associate_agent_with_custom_role
    return if @agent.blank?

    @agent.current_account_user.update!(custom_role_id: custom_role_id_param)
  end

  def custom_role_id_param
    params.dig(:agent, :custom_role_id).presence || params[:custom_role_id]
  end
end
