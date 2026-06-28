import { frontendURL } from 'dashboard/helper/URLHelper.js';
import {
  CRM_VIEW_PERMISSION,
  CRM_VIEW_REPORTS_PERMISSION,
  CRM_ADMIN_PERMISSION,
} from 'dashboard/constants/permissions.js';
import CrmKanbanPage from './pages/CrmKanbanPage.vue';
import CrmDashboardPage from './pages/CrmDashboardPage.vue';
import CrmAiUsagePage from './pages/CrmAiUsagePage.vue';
import CrmSlaPage from './pages/CrmSlaPage.vue';
import CrmIntegrationTokensPage from './pages/CrmIntegrationTokensPage.vue';
import CrmCampaignManagementPage from './pages/CrmCampaignManagementPage.vue';

// 'agent' keeps plain (non-custom-role) agents in per the locked decision;
// custom-role seats are gated by the granular crm_view permission key.
const meta = {
  permissions: ['administrator', 'agent', CRM_VIEW_PERMISSION],
};

const reportsMeta = {
  permissions: ['administrator', 'agent', CRM_VIEW_REPORTS_PERMISSION],
};

// Minting integration tokens is an admin-equivalent action: only the account
// administrator or an explicit crm_admin seat may reach the settings page.
const adminMeta = {
  permissions: ['administrator', CRM_ADMIN_PERMISSION],
};

const ensureCrmEnabled = (to, _from, next) => {
  if (window.globalConfig?.CRM_KANBAN_ENABLED === 'true') {
    next();
    return;
  }
  next({ name: 'home', params: to.params });
};

const ensureCrmAiEnabled = (to, _from, next) => {
  if (
    window.globalConfig?.CRM_KANBAN_ENABLED === 'true' &&
    window.globalConfig?.CRM_AI_ENABLED === 'true'
  ) {
    next();
    return;
  }
  next({ name: 'home', params: to.params });
};

export const routes = [
  {
    path: frontendURL('accounts/:accountId/crm'),
    name: 'crm_kanban_index',
    meta,
    beforeEnter: ensureCrmEnabled,
    component: CrmKanbanPage,
  },
  {
    // Calendar-only sub-page: reuses CrmKanbanPage but opens straight on the
    // calendar with the kanban/list/calendar switch + "New pipeline" hidden.
    path: frontendURL('accounts/:accountId/crm/calendar'),
    name: 'crm_calendar_index',
    meta: { ...meta, calendarOnly: true },
    beforeEnter: ensureCrmEnabled,
    component: CrmKanbanPage,
  },
  {
    path: frontendURL('accounts/:accountId/crm/dashboard'),
    name: 'crm_dashboard_index',
    meta: reportsMeta,
    beforeEnter: ensureCrmEnabled,
    component: CrmDashboardPage,
  },
  {
    path: frontendURL('accounts/:accountId/crm/ai-usage'),
    name: 'crm_ai_usage_index',
    meta: reportsMeta,
    beforeEnter: ensureCrmAiEnabled,
    component: CrmAiUsagePage,
  },
  {
    path: frontendURL('accounts/:accountId/crm/sla'),
    name: 'crm_sla_index',
    meta: adminMeta,
    beforeEnter: ensureCrmEnabled,
    component: CrmSlaPage,
  },
  {
    path: frontendURL('accounts/:accountId/crm/campaign-management'),
    name: 'crm_campaign_management_index',
    meta: reportsMeta,
    beforeEnter: ensureCrmEnabled,
    component: CrmCampaignManagementPage,
  },
  {
    path: frontendURL('accounts/:accountId/crm/settings/integration-tokens'),
    name: 'crm_integration_tokens_index',
    meta: adminMeta,
    beforeEnter: ensureCrmEnabled,
    component: CrmIntegrationTokensPage,
  },
];

export default { routes };
