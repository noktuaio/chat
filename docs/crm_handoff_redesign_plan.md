# CRM AI Handoff — Redesenho (R1 + R2 + R3 "bot-recepcionista")

Status: **design aprovado, sem código ainda**. Sessão de design 2026-06-29/30 (conta 3 / GTA).
Repo vivo: `chat2you` (deploy blue-green). Snapshot de referência: `chatwoot_customizado` (v4.15.1, cal73).

---

## 1. Problema (a dor real)

Quando a IA decide passar a conversa pra um humano, o handoff atual é um **alçapão só-ida**: ele atribui na hora e **cala o bot**, de forma irreversível, baseado em UMA mensagem. Se o cliente logo depois diz *"tudo bem, mas quero continuar aqui e fazer uma cotação"*, ninguém responde:
- a IA se calou (conversa saiu do escopo dela),
- o humano cravado pode não estar olhando.

Prova em prod (conta 3): dos últimos 40 `ai_handoff`, humanos responderam (não houve silêncio total nesta janela), MAS o padrão observado foi `assignee=nil` + `bot_reply=0` (bot calado) e a **mesma conversa handoffeada várias vezes** (churn). O bot some quando o cliente ainda queria ser atendido — inclusive em coisas que a própria IA resolveria (a cotação).

**Causa raiz:** o handoff acopla duas coisas que deviam ser separadas — *"chamar humano"* ≠ *"calar a IA e estacionar a conversa"*.

---

## 2. Fato-âncora verificado no código

**A ÚNICA alavanca que cala o bot é `conversation.assignee_id` (humano).**
- `reset_agent_bot_when_assignee_present` ([app/models/conversation.rb:278](../app/models/conversation.rb)): setar `assignee_id` auto-nula `assignee_agent_bot_id`.
- Agente nativo (Autonom.ia) gateia por **sem responsável** — status irrelevante ([app/services/autonomia/agents/operate.rb:15](../app/services/autonomia/agents/operate.rb): `return if conversation.assignee_id.present?`).
- Bot externo (n8n / webhook): listener dispara em TODA mensagem `webhook_sendable?`, sem olhar status ([app/listeners/agent_bot_listener.rb:43](../app/listeners/agent_bot_listener.rb)); o gate (IF por atribuição) vive no n8n.
- O conceito "bot só responde em `pending`" **morreu**: `bot_handoff!` ([conversation.rb:170](../app/models/conversation.rb)) só faz `open!` + `waiting_since` + emite `CONVERSATION_BOT_HANDOFF`; **não atribui** e **não cala** mais ninguém.

Consequência: handoff deve ser modelado como **intenção → primitiva nativa**, tendo `assignee_id` como única chave de silêncio.

---

## 3. As três regras (modelo final)

### R1 — Fundamento (já é assim)
Bot atende **enquanto a conversa não tem responsável humano**. Vale pro nativo e pro externo. Nada a "ligar"; só parar de duplicar trabalho (ver §5).

### R2 — Atribuição direta, mas SEGURA (para quem ainda quiser PUSH)
**Cenário real (conta 3, bot ativo):** auto-assignment nativo fica **v2 OFF** → o **handoff do CRM com IA é o atribuidor**, não o nativo. O nativo legado é "burro" (round-robin sobre online, sem pipeline/etapa/intenção); o handoff é o atribuidor **inteligente** (IA decide *quando* e *pra quem*). R2 NÃO delega ao nativo — mantém o handoff como atribuidor e adiciona a **trava de segurança** que falta hoje.

**Furo atual:** o executor crava direto (`@conversation.update!(assignee: agent)`) e o `HandoffMemberSelector` modo `prefer_online` **cai de volta pra lista inteira se ninguém estiver online** → pode cravar num agente OFFLINE → bot cala e ninguém atende (a dor).

**R2 (3 passos):**
1. IA decide passar (igual hoje).
2. **Antes de cravar, checa online de verdade** — reusar `OnlineStatusTracker.get_available_users` (presença Redis, janela 20s) ∩ membros elegíveis (caixa/time + nome sugerido pela IA). Mesma fonte canônica que `AutoAssignment::AgentAssignmentService` usa ([agent_assignment_service.rb:18](../app/services/auto_assignment/agent_assignment_service.rb)).
3. Bifurcação:
   - **Tem online** → crava no online via `Conversations::AssignmentService` (não `update!` na mão). Bot cala.
   - **Ninguém online** → **NÃO crava** → conversa sem responsável → bot segue atendendo (R1) + **job de drenagem** crava quando alguém ficar online.

O seletor passa a **filtrar por online de verdade** e **nunca** cair pra lista inteira. Inteligência da IA (nome/pipeline) vira o "quem"; online vira o gate.

### R3 — Convite por @menção ("bot-recepcionista" / PULL) — modelo preferido
Em vez de FORÇAR atribuição, o bot **convida** e **segura a linha** até um humano **se auto-atribuir**. **DECISÃO (Rodrigo): SEM nota privada na conversa.** O aviso é uma **notificação interna direta**, não uma mensagem no thread.
1. IA decide passar → adiciona o(s) agente(s) elegível(eis) como **participante** da conversa (`conversation_participants.find_or_create_by`, sem mensagem) + cria **Notificação** direto via `NotificationBuilder` ([notification_builder.rb](../app/builders/notification_builder.rb)) → push FCM + email + sininho in-app. Grava `invited_at`. **NÃO atribui. NÃO escreve mensagem.**
2. Bot **continua dono** (sem responsável) → segue atendendo o cliente (mata o dead-air; resolve "quero continuar a cotação").
3. Humano recebe **recado de verdade** (push + email + sininho — verificado: `NotificationBuilder#perform`→`process_notification_delivery` não exige mensagem) e **se auto-atribui** → bot cala (lever).
4. Resolve → **devolve pro bot** (desatribui / `assign_agent_bot`) → bot retoma.
5. **Telemetria de tempo-de-pega** (convite→auto-atribuição), inclusive **dentro do horário do agente** (ver §4).

Analogia: o bot é o recepcionista que avisa "a pessoa quer falar", fica na linha, e só larga quando o atendente pega.

---

## 4. Componentes que JÁ EXISTEM (o grosso é fiação, não construção)

| Peça do modelo | Componente existente | file |
|---|---|---|
| Recado chega de verdade | `conversation_mention` → push FCM + email + in-app | [notification.rb:42](../app/models/notification.rb), [notification/fcm_service.rb](../app/services/notification/fcm_service.rb) |
| Consult sem transferir | participantes + @menção em nota privada (não muda responsável) | [mention_service.rb:69](../app/services/messages/mention_service.rb), [conversation_participant.rb](../app/models/conversation_participant.rb) |
| Atribuição segura (online-only) | `AutoAssignment::AssignmentService#find_available_agent` (só `inbox.available_agents`) + RateLimiter + AssignmentPolicy | [app/services/auto_assignment/assignment_service.rb:49](../app/services/auto_assignment/assignment_service.rb) |
| Atribuir/voltar pro bot | `Conversations::AssignmentService` (`assign_agent` / `assign_agent_bot`) | [app/services/conversations/assignment_service.rb](../app/services/conversations/assignment_service.rb) |
| **Horário POR AGENTE** | `Crm::ServiceSchedule` (owner polimórfico **User**/Inbox, timezone, `blocks` dia/início/fim) + `AgentBookingProfile` + `Crm::Meetings::AvailabilityService` | [app/models/crm/service_schedule.rb](../app/models/crm/service_schedule.rb) |
| Online agora | `OnlineStatusTracker` (presença Redis, janela 20s) | [lib/online_status_tracker.rb:57](../lib/online_status_tracker.rb) |
| **Tempo dentro do horário** | `Sla::BusinessTimeCalculator.new(schedule:).elapsed_seconds(from,to)` — conta só segundos dentro dos blocos, DST-safe | [enterprise/app/services/sla/business_time_calculator.rb](../enterprise/app/services/sla/business_time_calculator.rb) |
| SLA / breach / escala | `sla_policies` (first/next/resolution thresholds + `only_during_business_hours`), `applied_slas`, jobs `Sla::*`, `Sla::AiBreachGuard` | [enterprise/app/models/sla_policy.rb](../enterprise/app/models/sla_policy.rb) |

> **Correção importante (eu havia errado):** horário-por-agente E engine de SLA **existem e são robustos** no chat2you. Não construir do zero — reusar.

---

## 5. O que é REALMENTE novo vs reuso

**Novo (pequeno — a fiação):**
1. Ação **"convite"** (R3): @menção + grava `invited_at` + NÃO atribui, disparada pela intenção da IA.
2. **Métrica tempo-de-pega** (convite→pega): **NÃO é SLA**. O motor de SLA ancora em marcos de mensagem/atribuição (`created_at`→`first_reply_created_at`, `waiting_since`, resolução — ver [evaluate_applied_sla_service.rb](../enterprise/app/services/sla/evaluate_applied_sla_service.rb)); não tem como expressar "convidei e ainda não foi atribuído". **Decisão fechada:** métrica **CRM própria** com timestamps nossos (`invited_at`, `picked_up_at` no card/activity), reusando **só** a função-folha pura `Sla::BusinessTimeCalculator.new(schedule: agenda_do_agente).elapsed_seconds(invited_at, picked_up_at)` (recebe agenda + 2 timestamps, devolve segundos úteis, DST-safe; não sabe nem se importa com o que os timestamps significam). `schedule` = `Crm::ServiceSchedule` do **agente** (owner=User). **Zero** acoplamento com `applied_sla`/`sla_policy`/`EvaluateAppliedSlaService`.
3. **Intenção do classificador**: `continuar | transferir | consultar` (mudança de prompt em `classifier_prompt.rb` / `stage_classifier.rb`).
4. **UI de Handoff apartada** (ver §6).
5. Modo R2 com gate de online + **job de drenagem** (mirror `stale_cards_job` / `auto_followup_scan_job`).

**Reuso (o peso, pronto):** agendas por agente, business-time, notificações reais, atribuição nativa online-gated, engine SLA.

**Limpeza junto:** parar de `update!(assignee:)` na mão → usar `Conversations::AssignmentService`; parar de logar `ai_handoff` em dobro (o `ASSIGNEE_CHANGED` já sincroniza o card); avaliar apagar o handoff morto dos Agentes Autonom.ia (`HandoffHandler`/`HandoffAssigner`/`CardHandoffLogger` — sem callers; `HANDOFF_STRATEGIES` indefinida) + o controle fantasma `handoff_strategy` em `PanelTune.vue`.

---

## 6. UI/UX — visão de Handoff APARTADA (fora de "Editar Funil")

Hoje o handoff está enfiado no painel de IA do pipeline (`CrmAiSettingsPanel.vue` dentro de `CrmPipelineDrawer.vue`): 3 conceitos no mesmo form, sem feedback ("passou pra quem"), trigger textarea sem validação, modo só `round_robin|direct` (falta time). UI ruim (confirmado pelo Rodrigo).

**Plano:** seção/tela dedicada de **Handoff** com configuração mais apurada:
- Modo por pipeline/estágio: **R2 (atribuição direta segura)** vs **R3 (convite por @menção)**.
- Pool: caixa inteira / time / pessoa específica (reusar picker de assignee nativo).
- Política de online (R2: só online; drenagem).
- Política de horário (qual `ServiceSchedule` conta pro SLA de pega).
- Threshold de tempo-de-pega + ação ao estourar (re-notifica / escala / supervisor).
- Feedback: "último handoff: há 8 min úteis, aguardando Maria".

---

## 7. Consult (sub-tema, em standby)
Especialista responde "uma coisa específica" sem transferir: via **participante + nota privada @menção** (não muda responsável; bot segue). v1 limpa = especialista escreve nota privada → **IA lê e repassa** (uma voz só pro cliente). Bot não pode ser participante (tabela só aceita `User`) — coexistência é assimétrica (bot=assignee-bot, humano=participante). Parte difícil = orquestrar "quem responde o cliente"; fica pra fase 2.

---

## 8. Decisões
1. ~~`assignment_v2` na conta 3?~~ **FECHADO:** com bot ativo, conta 3 roda **v2 OFF** (legado). Handoff do CRM é o atribuidor; nativo não compete. R2 = travar o handoff (não delegar ao nativo).
2. ~~Métrica tempo-de-pega reusa `applied_sla` ou própria?~~ **FECHADO:** métrica **CRM própria** (`invited_at`/`picked_up_at`) + só `BusinessTimeCalculator`. Não acoplar ao SLA (semântica errada).
3. ~~Cliente pede humano e ninguém online?~~ **FECHADO (Rodrigo, definitivo):** bot fica **calado atendendo a substância** até um humano chegar. SEM mensagem-meta tipo "vou te transferir". Nunca anunciar transferência ao cliente.
4. ~~Consult v1?~~ **FECHADO:** `consultar` em **standby no PR4** (sem efeito colateral). Fase 2.
5. **(novo, decisão Rodrigo)** R3 **não escreve nota privada**. Aviso = notificação interna direta (`NotificationBuilder`) + participante. Exige `notification_type` novo (ver §12).

---

## 9. Quebra provável em PRs
- **PR0** limpeza: delegar a `Conversations::AssignmentService`, parar log duplo, (opcional) apagar handoff morto dos Agentes + controle fantasma.
- **PR1** R3 convite: intenção `transferir` → @menção + `invited_at`, sem atribuir; bot segura.
- **PR2** telemetria tempo-de-pega (convite→pega) via `BusinessTimeCalculator` + `ServiceSchedule` do agente; breach/escala.
- **PR3** R2 seguro: gate online + delega auto-assignment + job de drenagem.
- **PR4** UI Handoff apartada + classificador `continuar|transferir|consultar`.

---

## 10. Notas de operação
- **SSM/instância EC2 rotaciona a cada deploy blue-green.** Não hardcodar instance-id; descobrir dinâmico: `aws ssm describe-instance-information --query "InstanceInformationList[?PingStatus=='Online'].InstanceId"` (hoje virou `i-0b63b3769dab33a0c`, green). Conta AWS 354307071110, região us-east-1, container `chatwoot-web`.
- Probe read-only sanitizado de prod: `scratchpad/handoff_deadair_probe.rb` (sem conteúdo de mensagem).

---

## 11. Plano técnico detalhado (codex, conferido no código)

### A. Dados
- **Config: sem tabela nova.** Reusar `crm_pipelines.metadata['ai']['handoff']` (default) + `crm_pipeline_stages.metadata['ai_handoff']` (override), já mesclados por `Crm::Ai::Config.handoff_settings` ([config.rb:138](../app/services/crm/ai/config.rb)). Expandir o JSON: `handoff_mode` (`r2_direct|r3_invite`), `selector_mode` (`round_robin|direct`), `pool_type`, `pool_id`, `pickup_threshold_seconds`, `renotify_after_seconds`, `escalation_user_id`. `mode` atual vira alias legado de `selector_mode`.
- **Runtime/telemetria: tabela nova `crm_ai_handoffs`** (status, invited_at, picked_up_at, candidate_user_ids, pickup_seconds, business_pickup_seconds, etc). `conversation_id` é **integer** (conversations.id é `serial` — NÃO usar `t.references` bigint). Índice parcial único por `account_id,conversation_id WHERE status pendente`. **Review:** para PR1 (MVP) várias colunas são antecipação (`business_pickup_seconds`, `breached_at`, `renotify_count`) — `crm_activities.payload`/card metadata cobririam log/config; a tabela só se justifica de fato para drain/renotify/pickup durável (PR2/PR3). Decidir: tabela enxuta no PR1 e crescer, ou full desde já.

### B. PRs (resumo técnico)
- **PR0:** `HandoffExecutor` troca `update!(assignee:)` → `Conversations::AssignmentService`; para log duplo (`ASSIGNEE_CHANGED`→`SyncConversationCardJob` já sincroniza). `HandoffMemberSelector` separa `eligible_pool` de `online_pool`.
- **PR1 (R3):** migration + model; `intent==transferir && handoff_mode==r3_invite` → cria `Crm::AiHandoff` pending + nota privada com menção → `MentionService` notifica; **sem** atribuir, **sem** `bot_handoff!`.
- **PR2:** `HandoffPickupRecorder` no `ConversationObserverListener#assignee_changed`; `business_pickup_seconds` via `Sla::BusinessTimeCalculator` (overlay enterprise `prepend_mod_with`) + `Crm::ServiceSchedule` do agente (lookup com `account_id`).
- **PR3 (R2):** gate online (`OnlineStatusTracker.get_available_users` ∩ pool); online→`Conversations::AssignmentService` (com lock + revalidar `assignee_id.nil?`); ninguém→`waiting_online`→drain.
- **PR4:** UI apartada + classificador `continuar|transferir|consultar`.

### C. Classificador
`stage_classifier.rb` hoje só aceita `handoff.should_handoff` com `additionalProperties:false`. Trocar p/ `handoff.intent` exige **schema + prompt + executor juntos** (não dá meio-termo). Aceitar `should_handoff:true` como `transferir` no rollout/cache.

## 12. Achados do review (codex) — CORRIGIR ANTES DE PR0/PR1

- **[CRÍTICO → RESOLVIDO pela decisão] Vazamento da nota privada p/ bot externo/n8n.** `webhook_sendable?` ([message_filter_helpers.rb](../app/models/concerns/message_filter_helpers.rb)) NÃO filtra `private` → a nota de @menção do R3 poderia disparar o webhook n8n. **Decisão Rodrigo elimina o risco:** R3 NÃO escreve mensagem nenhuma — usa `NotificationBuilder` direto (notificação interna) + participante. Sem `Message`, sem listener, sem vazamento. **Implica novo `notification_type`** (ex: `conversation_handoff_request`): os tipos atuais ou exigem mensagem (`conversation_mention`) ou implicam atribuição (`conversation_assignment`). Registrar no enum `Notification::NOTIFICATION_TYPES` + flags push/email em `NotificationSetting` + i18n, senão a entrega push/email faz no-op silencioso.
- **[RESOLVIDO — codex final] Handoff "morto" da Autonom.ia: É morto em runtime.** Fluxo vivo = `MessageListener`→`ReplyJob`→`Responder` ([responder.rb:43](../app/services/autonomia/agents/operate/responder.rb)); não chama o handler. `HandoffHandler`/`HandoffAssigner`/`CardHandoffLogger` só se chamam entre si; `HANDOFF_STRATEGIES` indefinida. **PR0 pode deletar os 3 arquivos.** NÃO deletar `Crm::Ai::HandoffMemberSelector` (vivo em `handoff_executor.rb:61`). `handoff_strategy` no `PanelTune.vue` = UI viva mas órfã/incompatível → remover como cleanup coordenado de UI/config. (O alerta anterior de "tem callers" foi falso-positivo.)
- **[ALTO] Classificador:** schema `additionalProperties:false` quebra com `intent` até schema+prompt+executor aceitarem ambos.
- **[ALTO] `handoff_settings` hoje só devolve `enabled/mode/trigger/prefer_online`** — novos campos exigem atualizar presenter/updater/UI/consumidores juntos.
- **[ALTO] `preferred_pool` (privado) cai pra todos elegíveis sem online** — PR3 precisa separar `online_pool`, senão nunca entra em `waiting_online`.
- **[ALTO] Presença 20s × cron 1min:** drain por polling perde janelas online. Avaliar cadência/janela maior (não há evento "agente ficou online").
- **[ALTO] R3 sem assign/sem bot_handoff! deixa conversa em `pending`** semanticamente "sob bot" — definir transição/status por modo.
- **[ALTO] `Conversations::AssignmentService` salva sem lock** — drain precisa travar a conversa e revalidar `assignee_id.nil?` dentro do lock.
- **[MÉDIO] Sintaxe de menção:** UX espera markdown `[@Nome](mention://user/ID/Name)` (URL-encode), não token cru.
- **[MÉDIO] Menção com sender nil** → push com remetente vazio; usar sender system/AgentBot ou copy dedicada.
- **[MÉDIO] enterprise/ é sempre carregado nesta fork** → "OSS nil" só seguro com `defined?` + schedule usável.
- **Veredito codex (1ª rodada):** não sólido p/ PR0+PR1 ainda. **(superado pela verificação final — ver §13.)**

---

## 13. Verificação final "sem regressão" (codex, read-only) — GO

Os 3 pontos foram fechados no código vivo:

1. **Autonom.ia handoff = morto em runtime** → PR0 deleta os 3 arquivos (ver §12, item resolvido). Manter `HandoffMemberSelector`.
2. **R3 sem mensagem é viável e mata o vazamento** (sem `Message` → sem `message_created` → sem webhook n8n; `operate.rb:14` só gateia por assignee). Participante sem mensagem é limpo (`conversation_participant.rb` sem callback de notificação/webhook). **MAS** o tipo de notificação novo **não entrega push/email por padrão** — o bit fica desligado até backfill. **Checklist obrigatório p/ o convite entregar de verdade (não só sininho):**
   - `app/models/notification.rb`: enum `conversation_handoff_request: 10` + `push_message_title`/`push_message_body`.
   - `app/models/notification_setting.rb` + migration: ligar/backfill o bit novo p/ usuários existentes (novos nascem só com assignment — `account_user.rb:52`).
   - `app/mailers/agent_notifications/conversation_notifications_mailer.rb`: método `conversation_handoff_request` (senão e-mail habilitado quebra no `public_send` — `email_notification_service.rb:21`) + template `.liquid`.
   - i18n backend (`en.yml`) + frontend (`settings.json`, `generalSettings.json`) + `profile/constants.js` (preferência no sininho).
   - Usar `secondary_actor: nil` (não o `AiHandoff`, que precisaria de `push_event_data`).
   - Atenção: `RemoveDuplicateNotificationJob` apaga por `user+primary_actor` sem filtrar tipo → múltiplos convites na mesma conversa = "último vence".
3. **Classificador:** `additionalProperties:false` rejeita `intent` se só o prompt mudar → schema+prompt juntos. **Sem cache de resposta** (`store:false`); mudar o prompt busta só o prefix cache, **não quebra resposta em voo**. Rollout: (1) schema+prompt devolvem `intent` mantendo `should_handoff`; (2) `HandoffExecutor#requested?` aceita `intent=='transferir'` OU `should_handoff==true`; (3) ligar R2/R3 por `intent`; `consultar`=no-op até PR4. Arquivos: `stage_classifier.rb`, `classifier_prompt.rb`, `handoff_executor.rb`, `evaluator.rb`.
4. **Drain (R2/held):** atribuir via `Conversations::AssignmentService` zera `assignee_agent_bot` (cala bot) — confirmado. Mas o service **não trava** → drain precisa de lock externo (`FOR UPDATE SKIP LOCKED` + revalidar `assignee_id.nil?`).

**Veredito final: GO para PR0 + PR1.** Trava única: **PR1 começa pelo `notification_type conversation_handoff_request` COMPLETO** (enum + flag/backfill + mailer + i18n), senão o convite aparece no banco/sininho mas não dispara push/email — convite que ninguém vê.

### UX (decidida): herança de configuração
"Atribuição" = 1 **padrão do funil** + **exceções por etapa**. Etapas herdam o padrão; só personaliza as exceções; **um Salvar** grava tudo. Mapeia no merge `pipeline default → stage override` do `Crm::Ai::Config.handoff_settings`. Botão "Atribuição" na barra do Kanban (ao lado de "Editar funil"); `Prioridade`/`Follow-up` migram p/ dentro de "Filtros".
