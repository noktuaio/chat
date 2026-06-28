# Plano técnico — Página "Gestão de IA" (Fase 3.2 do épico CRM AI)

Status: PLANEJADO. Pré-implementação. Decidido com Rodrigo em 2026-06-28.
Revisado por Codex em 2026-06-28 (1ª rodada — correções na seção 0).
Revisado por Codex (2ª rodada, crítico) em 2026-06-28 sobre as 3 decisões fechadas:
achou bloqueadores reais — contrato ActionCable do front (só `RoomChannel`), auth do
canal (Connection vazia), broadcast pós-commit, vazamento p/ stream da conta inteira,
`Rails.cache` não-Redis, fallback de cotação, modelo usado internamente p/ custo.
Tudo aplicado em 3.1, 3.4, 3.5, 3.6, 3.8, 3.9, 4.3, 5, 8. Veredito Codex: "precisa
corrigir antes" → corrigido no plano (implementação ainda não começou).

Decisões fechadas pelo Rodrigo em 2026-06-28 (resolvem a antiga seção 7):
1. **Modelo**: NÃO mostrar nome do modelo para ninguém. Sem coluna Modelo, sem
   caminho super-admin. Simplifica de vez.
2. **Tempo real**: SIM, de verdade. ActionCable — o `UsageRecorder` faz broadcast a
   cada evento gravado; a página recebe e atualiza. Sem poll.
3. **Moeda**: cotação DINÂMICA via API pública grátis (USD→BRL), com cache. Banco
   continua USD; conversão só na exibição.

Fonte de verdade do escopo: `docs/EPIC_CRM_AI_TUNING_E_CACHING.md` (seção 3.2 + 3.3).
Referência visual: mockup aprovado pelo Rodrigo (Gestão de IA — cards de topo, gasto
por recurso, gráfico semanal, histórico de uso, rodapé de privacidade).

Backend de captura (Fase 3.1) já está em prod: tabela `crm_ai_usage_events`,
`Crm::Ai::UsageRecorder`, `Crm::Ai::Pricing`, model `Crm::AiUsageEvent` com
`spend_by_feature` / `for_account` / `since`. Esta fase só LÊ esse dado e mostra.

---

## 0. Correções do Codex (contra o código real)

1. Super-admin "vê todas as contas" é INVIÁVEL nesta API account-scoped:
   `EnsureCurrentAccountHelper` exige vínculo `account_user`
   (`app/controllers/concerns/ensure_current_account_helper.rb:23`); super-admin de
   plataforma usa Devise separado `authenticate_super_admin!`
   (`app/controllers/super_admin/application_controller.rb:14`). Logo o endpoint do
   CRM SEMPRE escopa em `Current.account`. "Modelo só super-admin" dentro da conta
   não se sustenta — ver decisão #1.
2. Contrato real dos relatórios: rota é `scope :reports, controller: :reports` com
   `get :summary` etc. (`config/routes.rb:224`); `render_report` é privado do
   `ReportsController` (`reports_controller.rb:50`); builders retornam HASH CRU, o
   controller é que envelopa `{ payload: ... }` (`app/services/crm/reports/summary.rb:16`).
3. Mapa recurso→feature estava errado. Strings reais gravadas no `UsageRecorder`:
   `avaliacao_card`, `follow_up`, `email`, `resumo`, `resumo_reuniao`, `copilot`,
   `agente_resposta`, `sugestao_horario`, `convite`, `midia`, `kb_revisao`,
   `kb_instrucao`, `agente_builder`, `sla`.
4. `pipeline_id` não pode ser default obrigatório: várias chamadas gravam sem
   pipeline (copilot, email). Default = TODAS as pipelines.
5. Moeda: `cost_estimate` é USD decimal (`db/schema.rb:1069`), mas `formatMoney` do
   dashboard divide por 100 (centavos) — reuso ingênuo exibe errado.
6. Menu: não há menu secundário do CRM; o item vai no sidebar global
   `components-next/sidebar/Sidebar.vue:705`, gate `canViewCrmReports` (`:152`).
7. RBAC real: plain agent sem custom role TAMBÉM vê reports (OSS
   `Crm::ReportPolicy#view?` aceita qualquer `account_user`; EE libera admin + plain
   agent). Ajustar specs a isso.

## 1. Objetivo

Sub-página dentro do CRM (ao lado de Kanban / Calendário / Dashboard / SLA) que
mostra, em linguagem de produto, quanto a IA gastou: hoje / semana / mês, por
recurso, ao longo do tempo, com histórico e export. Privacidade rígida: nunca expor
prompt/resposta. Escopo sempre na conta atual.

## 2. Nomes na tela (humanizados)

Linguagem simples, não técnica. Sem nome de classe, sem "feature/chamada/cache".

- Título: **Gestão de IA**; selo **ao vivo**.
- Período: **Hoje · Semana · Mês**.
- Ação: **Baixar relatório** (CSV/JSON).
- Cards de topo: **Gasto na semana** · **Usos da IA** · **Economia automática** · **Custo médio por uso**.
- Seção esquerda: **Gasto por recurso** — barras horizontais com R$ por recurso.
- Seção direita: **Gasto na semana (por dia)** — gráfico de barras.
- Seção inferior: **Histórico de uso** — tabela: **Quando · Recurso · Conta · Tokens · Custo**.
  Sem coluna **Modelo** (decisão #1: modelo nunca aparece).
- Aviso da tabela: "Mostramos só o uso. O conteúdo das conversas nunca aparece aqui."
- Rodapé: "Nunca mostramos o conteúdo das conversas com a IA."

### Mapa recurso → feature (strings REAIS, validadas no código)
Interno ao builder, único lugar. NÃO vai pra tela.

| Recurso (tela) | feature(s) reais |
|---|---|
| Organizar cards | `avaliacao_card` |
| Lembretes de retorno | `follow_up` |
| Criação de e-mail | `email` |
| Resumos | `resumo`, `resumo_reuniao` |
| Assistente de respostas | `copilot`, `agente_resposta` |
| Agendamento | `sugestao_horario`, `convite` |
| Mídia | `midia` |
| Base de conhecimento | `kb_revisao`, `kb_instrucao` |
| Construtor de agente | `agente_builder` |
| SLA | `sla` |

Qualquer feature nova não mapeada cai em **"Outros"** (logar p/ não sumir gasto).

## 3. Backend

### 3.1 Builder de dados
Novo `app/services/crm/reports/ai_usage.rb` (`Crm::Reports::AiUsage`), assinatura
igual aos outros builders: `new(account:, params:).perform` → retorna **HASH CRU**
(o controller é quem envelopa em `{ payload: ... }`).

Responsabilidades:
- Agregados de topo (gasto período, nº de usos, % economia por cache, custo médio).
- Gasto por recurso: agrupa `spend_by_feature` pelo mapa da seção 2.
- Série temporal: soma `cost_estimate` por dia/hora respeitando `group_by`.
- Histórico paginado (sem conteúdo — só colunas de consumo, `select` explícito).
- % economia: `cached_tokens` vs preço cheio, reusando `Crm::Ai::Pricing`.
- Escopo SEMPRE `Crm::AiUsageEvent.for_account(account.id).since(...)`. Sem cross-account.
- `pipeline_id` é filtro OPCIONAL; default = todas as pipelines (não herdar default
  do dashboard, que subcontaria chamadas sem pipeline).
- Moeda: retornar `cost_usd` (decimal) e `cost_brl` convertido por cotação dinâmica
  (decisão #3) — ver 3.5. NUNCA mandar `cost_estimate` cru pro formatter de centavos.
- Modelo: USA `model` INTERNAMENTE (necessário p/ `Crm::Ai::Pricing.cost`, que indexa
  tarifa por modelo — `app/services/crm/ai/pricing.rb:21`; coluna existe em
  `db/schema.rb:1064`). Decisão #1 = nunca SERIALIZAR/exibir `model`, mas o builder
  precisa dele pra calcular custo e % economia. Calcular dentro, não mandar pro payload.
- % economia (correto, por modelo): `cached_tokens * (input_rate - cached_rate) / 1_000_000`.
  Sem o modelo o percentual sai errado — por isso o uso interno acima.

### 3.2 Controller
Novo `app/controllers/api/v1/accounts/crm/ai_usage_controller.rb`
(`< Crm::BaseController`). `render_report` é privado do ReportsController, então:
reimplementar o wrapper aqui (`render json: { payload: builder.perform }`) — NÃO
reusar o método do ReportsController.
- `before_action :ensure_crm_ai_enabled` (já existe na BaseController).
- `authorize %i[crm report], :view?` (Pundit) — policy `Crm::ReportPolicy` já existe.
- `index` → builder + render payload.
- `export` → mesmo builder, CSV/JSON, `Content-Disposition: attachment`.
- `report_params`: `permit(:since, :until, :group_by, :pipeline_id, :page, :format)`.

### 3.3 Rotas
`config/routes.rb`, dentro de `namespace :crm`, espelhando o `scope :reports`
existente (linha ~224):
```
scope :ai_usage, controller: :ai_usage do
  get '/',     action: :index
  get :export
end
```

### 3.4 RBAC + privacidade
- View: `crm report :view?` (`app/policies/crm/report_policy.rb`). REGRA REAL: admin
  + agent (inclusive plain agent sem custom role) veem; custom-role precisa de
  `crm_view_reports`. Specs batem essa regra, não uma mais restrita.
- Escopo de dados: SEMPRE a conta atual. Sem "ver todas".
- Conteúdo: nunca selecionar/serializar prompt/instrução/resposta. A tabela nem
  guarda isso (confirmar em `db/schema.rb` — só colunas de consumo). Export idem.
- Modelo: NUNCA exposto/serializado (decisão #1). Usado SÓ internamente no builder p/
  custo e % economia (ver 3.1). Não vai pro payload nem pro export.

### 3.5 Cotação dinâmica USD→BRL (decisão #3) — CORRIGIDO p/ Codex
Novo `app/services/crm/ai/exchange_rate.rb` (`Crm::Ai::ExchangeRate`).
- API pública grátis sem chave (ex.: AwesomeAPI `economia.awesomeapi.com.br`,
  exchangerate.host). Confirmar URL real antes de codar; não inventar endpoint. HTTP
  com timeout explícito como os services existentes (`responses_client.rb:83`,
  `waha/client.rb:7`).
- ⚠️ Codex ALTO: `Rails.cache` NÃO é Redis persistente garantido — `config.cache_store`
  comentado em `config/environments/production.rb:55`; dev memory/null, test null
  (`development.rb:17`, `test.rb:29`). O Redis existente é do ActionCable
  (`config/cable.yml`) e do Rack::Attack, não do `Rails.cache`. → Configurar
  `Rails.cache` p/ `:redis_cache_store` (decisão de infra, dentro ou antes do PR A) OU
  persistir a cotação noutro storage; senão cache de 1h não sobrevive entre processos/deploys.
- ⚠️ Codex ALTO: chave única expira e some. Usar DUAS chaves: `crm:ai:usd_brl:current`
  (TTL curto) + `crm:ai:usd_brl:last` (sem TTL, com timestamp p/ fallback stale).
- ⚠️ Codex MÉDIO: NÃO bater na API inline no request (latência/timeout quebram a página).
  Criar `Crm::Ai::ExchangeRateRefreshJob` agendado em `config/schedule.yml` (cron sidekiq
  já existe, `schedule.yml:17`) que atualiza o cache; request só LÊ. Inline só fallback
  com timeout curto que nunca levanta erro.
- Se API e cache falharem: expor `cost_usd` + `rate_unavailable: true` (front avisa).

### 3.6 Broadcast em tempo real (decisão #2) — CORRIGIDO p/ Codex
ActionCable, sem poll. O desenho anterior (`Crm::AiUsageChannel` + `stream_for account`)
NÃO funciona e vaza dado financeiro. Correções obrigatórias:
- ⚠️ Codex CRÍTICO (contrato front): o helper do dashboard só fala `RoomChannel` via
  `BaseActionCableConnector` (`app/javascript/shared/helpers/BaseActionCableConnector.js:17`,
  `app/javascript/dashboard/helper/actionCable.js:386`), identificado por `pubsub_token`
  + `account_id` + `user_id`. Canal novo não seria assinado por esse helper. → Reusar
  `RoomChannel`: emitir evento novo (ex.: `crm.ai_usage.created`) no broadcast e tratar
  esse `event` no connector existente.
- ⚠️ Codex CRÍTICO (auth do canal): `ApplicationCable::Connection` é vazio, sem
  `identified_by` (`app/channels/application_cable/connection.rb:1`). Auth real é manual
  no `RoomChannel` (acha `User` por `pubsub_token`, conta por
  `current_user.accounts.find(account_id)` — `room_channel.rb:42,56`). Reusar isso.
- ⚠️ Codex ALTO (vazamento): `RoomChannel` streama em `account_<id>` p/ TODO usuário da
  conta (`room_channel.rb:28`), mas reports exige `crm_view_reports` p/ custom-role
  (`enterprise/app/policies/enterprise/crm/report_policy.rb:4`). Broadcast de custo NÃO
  pode ir pro stream da conta inteira. → Broadcastar só pra `pubsub_token` dos usuários
  COM permissão de reports (resolver destinatários no broadcaster), ou canal dedicado
  com checagem Pundit na inscrição.
- ⚠️ Codex ALTO (pós-commit): `UsageRecorder.record` faz `create!` direto, sem callback
  (`app/services/crm/ai/usage_recorder.rb:7,10`); roda em request síncrono
  (`responses_client.rb:181`) E em job (`email_campaigns/ai/poll_job.rb:78`). Broadcast
  após `create!` pode sair antes do commit. → `after_create_commit` no model
  `Crm::AiUsageEvent` (`app/models/crm/ai_usage_event.rb`) chamando o broadcaster.
- Payload do broadcast: só delta de consumo (recurso, tokens, custo, timestamp). NUNCA
  conteúdo, NUNCA modelo. Front aplica delta em memória; refetch só na troca de período.

### 3.8 Allowlist de integration token — NOVO (Codex MÉDIO)
`Api::BaseController` aplica `restrict_integration_token_to_crm!`
(`app/controllers/api/base_controller.rb:9`) e a allowlist só lista
`api/v1/accounts/crm/reports` (`restrict_integration_token_to_crm.rb:71`). O novo
controller `crm/ai_usage` fica BLOQUEADO p/ integration token até decidir:
(a) adicionar `api/v1/accounts/crm/ai_usage` → `{ index, export } => crm_view_reports`, ou
(b) declarar que integration token não acessa essa API.

### 3.9 Enterprise overlay — CORRIGIDO p/ Codex
Override real de reports é `enterprise/app/policies/enterprise/crm/report_policy.rb:1`;
`enterprise/app/policies/crm_permissions.rb:8` é helper compartilhado, NÃO o lugar do
override. Reusar a mesma porta (`crm report :view?`); não criar policy nova.

## 4. Frontend

Clonar a estrutura de `CrmDashboardPage.vue`, trocando a fonte de dados. Zero lib nova.

### 4.1 Arquivos
- Página: `app/javascript/dashboard/routes/dashboard/crm/pages/CrmAiUsagePage.vue`.
- Rota: `crm.routes.js` — `name: 'crm_ai_usage_index'`, path `.../crm/ai-usage`,
  `meta: reportsMeta`, `beforeEnter: ensureCrmEnabled`.
- Menu: `app/javascript/dashboard/components-next/sidebar/Sidebar.vue` (~linha 705,
  onde o CRM monta seus itens), novo item gateado por `canViewCrmReports` (`:152`).
- API: novo `app/javascript/dashboard/api/crmAiUsage.js` (ou método em `crmKanban.js`
  seguindo como o dashboard chama reports) — `get(params)` + `export(params)`.
- i18n: `en/crm.json` + `pt_BR/crm.json`.

### 4.2 Componentes reusados
- Cards de topo: `ReportMetricCard` (`routes/dashboard/settings/reports/components/ReportMetricCard.vue`).
- Gráfico: `BarChart` (`shared/components/charts/BarChart.vue`).
- Gasto por recurso: barras horizontais em Tailwind (width %).
- Botões/Spinner: `components-next/button`, `components-next/spinner`.
- MOEDA: NÃO reusar `formatMoney` do CrmDashboardPage (divide por 100 = centavos).
  Formatar a partir de `cost_usd`/`cost_brl` decimal vindo do backend.

### 4.3 Período + tempo real — CORRIGIDO p/ Codex
- Toggle Hoje/Semana/Mês → `{ since, group_by }` (Hoje=hora, Semana/Mês=dia).
- "Ao vivo": **ActionCable via `RoomChannel` existente** (não canal novo — ver 3.6).
  Registrar handler do evento novo `crm.ai_usage.created` no `BaseActionCableConnector`/
  `actionCable.js` (mesmo mecanismo dos outros eventos). Aplica delta em memória (cards
  + série + topo do histórico). Refetch completo só ao trocar de período. Sem poll.
- Corrida delta×refetch: aplicar delta só após refetch resolver; descartar evento com
  timestamp anterior ao `since` atual.
- Moeda exibida vem de `cost_brl`; se `rate_unavailable`, mostra USD com aviso curto.

## 5. Testes
- Backend builder: agregados, % cache, série por group_by, mapa recurso→feature com
  as strings reais, escopo só na conta, moeda decimal correta, `model` ausente do payload.
- Backend controller: Pundit (admin/agent OK; custom-role sem `crm_view_reports`
  negado); export CSV/JSON com headers; nenhuma coluna de conteúdo/modelo no payload.
- ExchangeRate: usa cache quando presente; fallback p/ último valor; `rate_unavailable`
  quando API e cache falham (stub da chamada externa, sem hit real em teste).
- Broadcast: `after_create_commit` dispara só após commit; só usuários COM
  `crm report :view?` recebem (não vaza pro stream da conta inteira); payload sem
  conteúdo nem modelo.
- ExchangeRateRefreshJob: agenda atualiza cache; request lê sem bater na API.
- Frontend: render cards + gasto por recurso (mapa humanizado); moeda de `cost_brl`
  (não centavos); delta do ActionCable atualiza cards sem refetch; troca de período refetch.

## 6. Rollout / rollback
- Atrás de `Crm::Ai::Config.enabled?` + `CRM_KANBAN_ENABLED`.
- Sem migration. Deploy blue-green das 2 stacks (memória deploy-blue-green-prod).
  Rollback = re-deploy do main anterior.
- Risco: Baixo. Só leitura/agregação.

## 7. Decisões (FECHADAS em 2026-06-28)
1. **Modelo**: nunca exposto, para ninguém. Sem coluna Modelo, sem caminho
   super-admin. (ver topo do doc)
2. **Tempo real**: ActionCable com broadcast no `UsageRecorder` (3.6). Sem poll.
3. **Moeda**: cotação dinâmica USD→BRL via API grátis, com cache (3.5). Banco USD.

## 8. Quebra em PRs
- PR 0 (infra, pré-requisito): configurar `Rails.cache` → `:redis_cache_store`
  (`production.rb:55` hoje comentado). Necessário pro cache da cotação sobreviver entre
  processos/deploys. Decisão de infra — confirmar com Rodrigo (toca config de prod).
- PR A (backend): builder + controller + rota + allowlist integration-token (3.8) +
  `ExchangeRate` + `ExchangeRateRefreshJob` (schedule.yml) + `after_create_commit` em
  `Crm::AiUsageEvent` + broadcaster via `RoomChannel` (só destinatários permitidos) +
  specs. `Part of #24`.
- PR B (frontend): página + rota + menu (Sidebar.vue) + API client + handler do evento
  `crm.ai_usage.created` no actionCable + i18n + specs. `Part of #24`.
- Cada PR: lint + rspec/vitest + Codex review antes do merge; deploy só com 🟢.

## 9. Aceite (do épico 3.2/3.3)
Página mostra gasto ao vivo (ActionCable) + % economia; export CSV/JSON; valores em
R$ por cotação dinâmica; nomes em linguagem de produto; nenhum prompt/resposta/modelo
vaza; escopo só na conta.
