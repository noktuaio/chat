require 'csv'

class Api::V1::Accounts::Crm::AiUsageController < Api::V1::Accounts::Crm::BaseController
  before_action :ensure_crm_ai_enabled
  before_action :authorize_reports

  def index
    render json: { payload: builder.perform }
  end

  def export
    payload = builder.perform
    # `:format` is forced to json by the API routes, so the export type comes in a
    # dedicated `export_format` query param (defaults to CSV).
    report_format = params[:export_format].to_s == 'json' ? 'json' : 'csv'

    return export_json(payload) if report_format == 'json'

    export_csv(payload)
  end

  private

  def authorize_reports
    authorize %i[crm report], :view?
  end

  def builder
    ::Crm::Reports::AiUsage.new(account: Current.account, params: report_params)
  end

  def export_json(payload)
    send_data payload.to_json,
              filename: export_filename('json'),
              type: 'application/json; charset=utf-8',
              disposition: 'attachment'
  end

  def export_csv(payload)
    send_data csv_for(payload),
              filename: export_filename('csv'),
              type: 'text/csv; charset=utf-8',
              disposition: 'attachment'
  end

  def csv_for(payload)
    CSV.generate do |csv|
      csv << ['Quando', 'Recurso', 'Conta', 'Tokens', 'Custo USD', 'Custo BRL']
      payload.dig(:history, :rows).to_a.each do |row|
        csv << [
          row[:created_at],
          csv_safe(row[:resource]),
          csv_safe(row.dig(:account, :name)),
          row[:total_tokens],
          row[:cost_usd],
          row[:cost_brl]
        ]
      end
    end
  end

  def csv_safe(value)
    string = value.to_s
    return string unless string.start_with?('=', '+', '-', '@', "\t", "\r")

    "'#{string}"
  end

  def export_filename(extension)
    "crm_ai_usage_#{Time.current.strftime('%Y%m%d%H%M%S')}.#{extension}"
  end

  def report_params
    params.permit(:since, :until, :group_by, :pipeline_id, :page, :format)
  end
end
