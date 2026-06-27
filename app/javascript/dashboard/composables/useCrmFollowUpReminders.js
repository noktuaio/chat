import { computed, ref } from 'vue';
import CrmKanbanAPI from 'dashboard/api/crmKanban';

const queue = ref([]);
const seenIds = new Set();

const isCrmEnabled = () =>
  window.globalConfig?.CRM_KANBAN_ENABLED === 'true' ||
  window.globalConfig?.crmKanbanEnabled === true;

export function useCrmFollowUpReminders() {
  const activeReminder = computed(() => queue.value[0] || null);
  const hasReminder = computed(() => queue.value.length > 0);

  // account_id is serialized by both reminder sources — the CRM_FOLLOW_UP_DUE
  // websocket (Broadcaster) and the GET reminders poll (_follow_up partial). No
  // client-side fallback: window.chatwootConfig never carried an account id, so
  // the old fallback silently produced `undefined`, breaking openCrm and the
  // account-scoped complete/dismiss calls.
  const normalizeReminder = payload => ({ ...payload });

  const enqueueReminder = payload => {
    if (!isCrmEnabled() || !payload?.id) return;
    if (seenIds.has(payload.id)) return;
    if (queue.value.some(item => item.id === payload.id)) return;

    seenIds.add(payload.id);
    queue.value.push(normalizeReminder(payload));
  };

  const dequeueReminder = () => {
    const removed = queue.value.shift();
    if (removed?.id !== undefined) {
      seenIds.delete(removed.id);
    }
  };

  const fetchMissedReminders = async () => {
    if (!isCrmEnabled()) return;

    try {
      const response = await CrmKanbanAPI.getFollowUpReminders();
      (response.data.payload || []).forEach(enqueueReminder);
    } catch {
      // Non-blocking bootstrap for popup reminders.
    }
  };

  const completeReminder = async (id, accountId) => {
    try {
      await CrmKanbanAPI.completeFollowUpForAccount(accountId, id);
    } finally {
      // Always dismiss the popup on click, even if the API rejects
      // (e.g. cross-account 404 or an already-completed reminder).
      dequeueReminder();
    }
  };

  const dismissReminder = async (id, accountId) => {
    try {
      await CrmKanbanAPI.dismissFollowUpReminderForAccount(accountId, id);
    } finally {
      dequeueReminder();
    }
  };

  return {
    activeReminder,
    hasReminder,
    enqueueReminder,
    dequeueReminder,
    fetchMissedReminders,
    completeReminder,
    dismissReminder,
    isCrmEnabled,
  };
}
