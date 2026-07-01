<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';

defineProps({
  agentOptions: { type: Array, default: () => [] },
});

const form = defineModel({ type: Object, required: true });

const { t } = useI18n();

const FLOW_MODES = ['r2_direct', 'r3_invite'];
const POOL_TYPES = ['inbox', 'user'];
const ESCALATION_ACTIONS = ['renotify', 'escalate'];
const SELECTOR_MODES = ['round_robin', 'direct'];

const DEFAULT_PICKUP_THRESHOLD_SECONDS = 900;

const pickupThresholdMinutes = computed({
  get: () => {
    const seconds =
      Number(form.value.pickup_threshold_seconds) ||
      DEFAULT_PICKUP_THRESHOLD_SECONDS;
    return Math.max(1, Math.round(seconds / 60));
  },
  set: value => {
    const minutes = Number(value);
    form.value.pickup_threshold_seconds =
      (minutes > 0 ? Math.round(minutes) : 1) * 60;
  },
});

const setFlowMode = mode => {
  form.value.handoff_mode = mode;
};

const setPoolType = type => {
  form.value.pool_type = type;
  if (type === 'inbox') form.value.pool_id = null;
};

const setEscalationAction = action => {
  form.value.escalation_action = action;
};
</script>

<template>
  <label class="flex items-center gap-2 text-sm text-n-slate-12">
    <input
      v-model="form.enabled"
      type="checkbox"
      class="rounded border-n-weak"
    />
    {{ t('CRM_KANBAN.AI_SETTINGS.HANDOFF.ENABLED') }}
  </label>

  <template v-if="form.enabled">
    <div class="grid gap-1">
      <span class="text-xs text-n-slate-11">
        {{ t('CRM_KANBAN.HANDOFF_DRAWER.FLOW_MODE') }}
      </span>
      <div class="flex w-full items-center gap-1 rounded-lg bg-n-alpha-2 p-0.5">
        <button
          v-for="flow in FLOW_MODES"
          :key="flow"
          type="button"
          class="flex-1 rounded-md px-2 py-1 text-xs"
          :class="
            form.handoff_mode === flow
              ? 'bg-n-solid-3 text-n-slate-12'
              : 'text-n-slate-11'
          "
          @click="setFlowMode(flow)"
        >
          {{ t(`CRM_KANBAN.HANDOFF_DRAWER.FLOW_MODE_${flow.toUpperCase()}`) }}
        </button>
      </div>
    </div>

    <textarea
      v-model="form.trigger"
      rows="2"
      class="reset-base w-full rounded-lg border-0 bg-n-surface-2 px-3 py-2 text-sm text-n-slate-12 outline outline-1 outline-n-weak"
      :placeholder="t('CRM_KANBAN.AI_SETTINGS.HANDOFF.TRIGGER_PLACEHOLDER')"
    />

    <div class="grid gap-1">
      <span class="text-xs text-n-slate-11">
        {{ t('CRM_KANBAN.HANDOFF_DRAWER.ASSIGN_TO') }}
      </span>
      <div class="flex w-full items-center gap-1 rounded-lg bg-n-alpha-2 p-0.5">
        <button
          v-for="pool in POOL_TYPES"
          :key="pool"
          type="button"
          class="flex-1 rounded-md px-2 py-1 text-xs"
          :class="
            form.pool_type === pool
              ? 'bg-n-solid-3 text-n-slate-12'
              : 'text-n-slate-11'
          "
          @click="setPoolType(pool)"
        >
          {{ t(`CRM_KANBAN.HANDOFF_DRAWER.POOL_TYPE_${pool.toUpperCase()}`) }}
        </button>
      </div>
    </div>

    <label
      v-if="form.pool_type === 'user'"
      class="flex items-center gap-2 text-xs text-n-slate-11"
    >
      {{ t('CRM_KANBAN.HANDOFF_DRAWER.POOL_USER') }}
      <select
        v-model="form.pool_id"
        class="reset-base max-w-52 rounded-lg border-0 bg-n-surface-2 px-2 py-1 text-xs text-n-slate-12 outline outline-1 outline-n-weak"
      >
        <option :value="null">
          {{ t('CRM_KANBAN.HANDOFF_DRAWER.POOL_USER_NONE') }}
        </option>
        <option
          v-for="agent in agentOptions"
          :key="agent.value"
          :value="agent.value"
        >
          {{ agent.label }}
        </option>
      </select>
    </label>

    <label v-else class="flex items-center gap-2 text-xs text-n-slate-11">
      {{ t('CRM_KANBAN.AI_SETTINGS.HANDOFF.MODE') }}
      <select
        v-model="form.mode"
        class="reset-base rounded-lg border-0 bg-n-surface-2 px-2 py-1 text-xs text-n-slate-12 outline outline-1 outline-n-weak"
      >
        <option v-for="mode in SELECTOR_MODES" :key="mode" :value="mode">
          {{ t(`CRM_KANBAN.AI_SETTINGS.HANDOFF.MODE_${mode.toUpperCase()}`) }}
        </option>
      </select>
    </label>

    <div class="grid gap-1">
      <label class="flex items-center gap-2 text-xs text-n-slate-12">
        <input
          v-model="form.prefer_online"
          type="checkbox"
          class="rounded border-n-weak"
        />
        {{ t('CRM_KANBAN.AI_SETTINGS.HANDOFF.PREFER_ONLINE') }}
      </label>
      <p
        v-if="form.prefer_online && form.handoff_mode === 'r3_invite'"
        class="mb-0 ltr:pl-6 rtl:pr-6 text-xs leading-5 text-n-slate-10"
      >
        {{ t('CRM_KANBAN.HANDOFF_DRAWER.PREFER_ONLINE_HINT_INVITE') }}
      </p>
      <p
        v-else-if="form.prefer_online"
        class="mb-0 ltr:pl-6 rtl:pr-6 text-xs leading-5 text-n-slate-10"
      >
        {{ t('CRM_KANBAN.HANDOFF_DRAWER.PREFER_ONLINE_HINT_DIRECT') }}
      </p>
    </div>

    <div v-if="form.handoff_mode === 'r3_invite'" class="grid gap-2">
      <label class="flex items-center gap-2 text-xs text-n-slate-11">
        {{ t('CRM_KANBAN.HANDOFF_DRAWER.PICKUP_THRESHOLD_MINUTES') }}
        <input
          v-model="pickupThresholdMinutes"
          type="number"
          min="1"
          class="reset-base w-20 rounded-lg border-0 bg-n-surface-2 px-2 py-1 text-xs text-n-slate-12 outline outline-1 outline-n-weak"
        />
      </label>

      <div class="flex w-full items-center gap-1 rounded-lg bg-n-alpha-2 p-0.5">
        <button
          v-for="action in ESCALATION_ACTIONS"
          :key="action"
          type="button"
          class="flex-1 rounded-md px-2 py-1 text-xs"
          :class="
            form.escalation_action === action
              ? 'bg-n-solid-3 text-n-slate-12'
              : 'text-n-slate-11'
          "
          @click="setEscalationAction(action)"
        >
          {{
            t(
              `CRM_KANBAN.HANDOFF_DRAWER.ESCALATION_ACTION_${action.toUpperCase()}`
            )
          }}
        </button>
      </div>

      <label
        v-if="form.escalation_action === 'escalate'"
        class="flex items-center gap-2 text-xs text-n-slate-11"
      >
        {{ t('CRM_KANBAN.HANDOFF_DRAWER.ESCALATION_USER') }}
        <select
          v-model="form.escalation_user_id"
          class="reset-base max-w-52 rounded-lg border-0 bg-n-surface-2 px-2 py-1 text-xs text-n-slate-12 outline outline-1 outline-n-weak"
        >
          <option :value="null">
            {{ t('CRM_KANBAN.HANDOFF_DRAWER.ESCALATION_USER_NONE') }}
          </option>
          <option
            v-for="agent in agentOptions"
            :key="agent.value"
            :value="agent.value"
          >
            {{ agent.label }}
          </option>
        </select>
      </label>
    </div>
  </template>
</template>
