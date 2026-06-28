class Api::V1::Accounts::Autonomia::Agents::PlaygroundController < Api::V1::Accounts::Autonomia::BaseController
  # Herda BaseController: gate de feature flag (404 com flag off) + ensure_account_administrator +
  # agents_scope (isolamento por conta). Sandbox puro: nada é persistido, não há conversa/inbox real.
  before_action :fetch_agent

  # POST .../agents/:id/test -> Playground (Testar)
  # MULTIMODAL: aceita `images` (array de data-urls) anexadas à mensagem atual. Síncrono e volátil — as
  # imagens chegam inline em base64 (sem ActiveStorage); o modelo as lê como input_image neste turno.
  def test
    return render_unprocessable('message_required') if message_param.blank?

    @result = Autonomia::Agents::Playground.new(
      agent: @agent, message: message_param, history: history_param, images: images_param
    ).run
    render :test
  end

  # POST .../agents/:id/suggest -> Copilot (rascunho ao atendente; sempre devolve reply)
  def suggest
    return render_unprocessable('message_required') if message_param.blank?

    @result = Autonomia::Agents::Copilot.new(agent: @agent, message: message_param, history: history_param).suggest
    render :suggest
  end

  private

  def fetch_agent
    @agent = agents_scope.find(params[:id])
  end

  def message_param
    params.require(:message).to_s
  end

  # history opcional: array de [{ role, content }]; saneado no PromptBuilder. Itens em branco caem.
  def history_param
    Array(params[:history]).filter_map do |h|
      next if h.blank?

      { role: h[:role].to_s, content: h[:content].to_s }
    end
  end

  # MULTIMODAL: data-urls de imagem anexadas à mensagem atual. Validação é AUTORIDADE no BE (o FE só
  # avisa): só data:image/<allowlist>;base64,<payload>, ≤MAX_IMAGE_BYTES decodificado, ≤MAX_IMAGES.
  # Itens inválidos são DESCARTADOS (não derrubam o request — o turno segue com o texto). NUNCA loga o
  # conteúdo da imagem.
  def images_param
    Array(params[:images])
      .filter_map { |raw| valid_image_data_url(raw.to_s) }
      .first(Autonomia::Agents::Config::MAX_IMAGES_PER_MESSAGE)
  end

  IMAGE_DATA_URL_RE = %r{\Adata:(?<type>image/[a-z+]+);base64,(?<data>[A-Za-z0-9+/=\s]+)\z}

  def valid_image_data_url(raw)
    match = IMAGE_DATA_URL_RE.match(raw)
    return nil if match.nil?
    return nil unless Autonomia::Agents::Config::IMAGE_CONTENT_TYPES.include?(match[:type])

    payload = match[:data].gsub(/\s+/, '')
    decoded = Base64.strict_decode64(payload)
    return nil if decoded.bytesize > Autonomia::Agents::Config::MAX_IMAGE_BYTES

    "data:#{match[:type]};base64,#{payload}"
  rescue ArgumentError
    nil # base64 inválido — descarta a imagem, mantém o turno.
  end
end
