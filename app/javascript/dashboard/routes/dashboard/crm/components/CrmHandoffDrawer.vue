<script setup>
import { computed, reactive, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { useMapGetter, useStore } from 'dashboard/composables/store';
import Button from 'dashboard/components-next/button/Button.vue';
import CrmKanbanAPI from 'dashboard/api/crmKanban';
import { useKeyboardEvents } from 'dashboard/composables/useKeyboardEvents';

const props = defineProps({
  show: { type: Boolean, default: false },
  pipelineId: { type: [String, Number], default: null },
  stages: { type: Array, default: () => [] },
});

const emit = defineEmits(['close']);

const { t } = useI18n();
const store = useStore();
const agents = useMapGetter('agents/getAgents');

const SELECTOR_MODES = ['round_robin', 'direct'];
const FLOW_MODES = ['r2_direct', 'r3_invite'];
const HANDOFF_PICKUP_THRESHOLD_DEFAULT = 900;

const isLoading = ref(false);
const isSaving = ref(false);
const loadFailed = ref(false);

const defaultHandoff = reactive({
  enabled: false,
  mode: 'round_robin',
  handoff_mode: 'r2_direct',
  trigger: '',
  prefer_online: true,
  pickup_threshold_seconds: HANDOFF_PICKUP_THRESHOLD_DEFAULT,
  escalation_user_id: null,
});

const stageForms = reactive({});

const namedStages = () => props.stages.filter(stage => stage.id);
const agentOptions = computed(() =>
  agents.value.map(agent => ({ value: agent.id, label: agent.name }))
);

const normalizePositiveSeconds = value => {
  const seconds = Number(value);
  return seconds > 0 ? Math.round(seconds) : HANDOFF_PICKUP_THRESHOLD_DEFAULT;
};

const normalizeUserId = value => {
  const userId = Number(value);
  return Number.isInteger(userId) && userId > 0 ? userId : null;
};

const toFormEntry = handoff => ({
  enabled: handoff?.enabled === true,
  mode: SELECTOR_MODES.includes(handoff?.mode) ? handoff.mode : 'round_robin',
  handoff_mode: FLOW_MODES.includes(handoff?.handoff_mode)
    ? handoff.handoff_mode
    : 'r2_direct',
  trigger: handoff?.trigger || '',
  prefer_online: handoff?.prefer_online !== false,
  pickup_threshold_seconds: normalizePositiveSeconds(
    handoff?.pickup_threshold_seconds
  ),
  escalation_user_id: normalizeUserId(handoff?.escalation_user_id),
});

const defaultPickupThresholdMinutes = computed({
  get: () =>
    Math.max(1, Math.round(defaultHandoff.pickup_threshold_seconds / 60)),
  set: value => {
    const minutes = Number(value);
    defaultHandoff.pickup_threshold_seconds =
      (minutes > 0 ? Math.round(minutes) : 1) * 60;
  },
});

const pickupThresholdMinutes = form =>
  Math.max(
    1,
    Math.round(normalizePositiveSeconds(form?.pickup_threshold_seconds) / 60)
  );

const updatePickupThresholdMinutes = (form, value) => {
  const minutes = Number(value);
  form.pickup_threshold_seconds = (minutes > 0 ? Math.round(minutes) : 1) * 60;
};

const loadSettings = async () => {
  if (!props.pipelineId) return;
  isLoading.value = true;
  loadFailed.value = false;
  try {
    const response = await CrmKanbanAPI.getAiSettings(props.pipelineId);
    const payload = response.data.payload || {};
    Object.assign(defaultHandoff, toFormEntry(payload.handoff));

    Object.keys(stageForms).forEach(key => delete stageForms[key]);
    (payload.stages || []).forEach(stage => {
      stageForms[stage.id] = {
        custom: stage.handoff_custom === true,
        ...toFormEntry(stage.handoff),
      };
    });
  } catch {
    loadFailed.value = true;
    useAlert(t('CRM_KANBAN.HANDOFF_DRAWER.LOAD_ERROR'));
  } finally {
    isLoading.value = false;
  }
};

const inheritedSummary = stageId => {
  const custom = stageForms[stageId];
  if (!custom) return '';
  const status = defaultHandoff.enabled
    ? t('CRM_KANBAN.HANDOFF_DRAWER.STATUS_ON')
    : t('CRM_KANBAN.HANDOFF_DRAWER.STATUS_OFF');
  const flow = t(
    `CRM_KANBAN.HANDOFF_DRAWER.FLOW_MODE_${defaultHandoff.handoff_mode.toUpperCase()}`
  );
  return t('CRM_KANBAN.HANDOFF_DRAWER.INHERITED_SUMMARY', { status, flow });
};

const saveSettings = async () => {
  if (!props.pipelineId) return;
  isSaving.value = true;
  try {
    const stageHandoff = Object.fromEntries(
      Object.entries(stageForms).map(([stageId, form]) => [
        stageId,
        form.custom
          ? {
              custom: true,
              enabled: form.enabled,
              mode: form.mode,
              handoff_mode: form.handoff_mode,
              trigger: form.trigger,
              prefer_online: form.prefer_online,
              pickup_threshold_seconds: form.pickup_threshold_seconds,
              escalation_user_id: form.escalation_user_id,
            }
          : { custom: false },
      ])
    );
    await CrmKanbanAPI.updateAiSettings(props.pipelineId, {
      ai_settings: { handoff: { ...defaultHandoff } },
      stage_handoff: stageHandoff,
    });
    useAlert(t('CRM_KANBAN.HANDOFF_DRAWER.SAVE_SUCCESS'));
  } catch {
    useAlert(t('CRM_KANBAN.HANDOFF_DRAWER.SAVE_ERROR'));
  } finally {
    isSaving.value = false;
  }
};

watch(
  () => [props.show, props.pipelineId],
  () => {
    if (props.show) {
      store.dispatch('agents/get');
      loadSettings();
    }
  },
  { immediate: true }
);

useKeyboardEvents({
  Escape: {
    action: () => {
      if (props.show) emit('close');
    },
    allowOnFocusedInput: true,
  },
});
</script>

<template>
  <transition
    enter-active-class="transition duration-200 ease-out"
    enter-from-class="ltr:translate-x-full rtl:-translate-x-full opacity-0"
    leave-active-class="transition duration-150 ease-in"
    leave-to-class="ltr:translate-x-[30%] rtl:-translate-x-[30%] opacity-0"
  >
    <div
      v-if="show"
      class="fixed inset-y-0 ltr:right-0 rtl:left-0 z-50 flex h-full w-[36rem] max-w-full flex-col overflow-hidden border-n-weak bg-n-surface-2 shadow-lg ltr:border-l rtl:border-r"
    >
      <div
        class="flex items-start justify-between gap-4 border-b border-n-weak px-6 py-5"
      >
        <div class="min-w-0">
          <h2 class="mb-1 text-lg font-medium text-n-slate-12">
            {{ t('CRM_KANBAN.HANDOFF_DRAWER.TITLE') }}
          </h2>
          <p class="mb-0 text-sm leading-5 text-n-slate-11">
            {{ t('CRM_KANBAN.HANDOFF_DRAWER.SUBTITLE') }}
          </p>
        </div>
        <Button icon="i-lucide-x" slate ghost sm @click="$emit('close')" />
      </div>

      <div class="flex-1 overflow-y-auto px-6 py-5">
        <p v-if="isLoading" class="mb-0 text-sm text-n-slate-11">
          {{ t('CRM_KANBAN.HANDOFF_DRAWER.LOADING') }}
        </p>
        <p v-else-if="loadFailed" class="mb-0 text-sm text-n-ruby-11">
          {{ t('CRM_KANBAN.HANDOFF_DRAWER.LOAD_ERROR') }}
        </p>

        <div v-else class="grid gap-5">
          <section
            class="grid gap-3 rounded-lg border border-n-weak bg-n-alpha-black2 p-4"
          >
            <div>
              <h3 class="mb-1 text-sm font-medium text-n-slate-12">
                {{ t('CRM_KANBAN.HANDOFF_DRAWER.DEFAULT_SECTION_TITLE') }}
              </h3>
              <p class="mb-0 text-xs leading-5 text-n-slate-11">
                {{ t('CRM_KANBAN.HANDOFF_DRAWER.DEFAULT_SECTION_HELP') }}
              </p>
            </div>

            <label class="flex items-center gap-2 text-sm text-n-slate-12">
              <input
                v-model="defaultHandoff.enabled"
                type="checkbox"
                class="rounded border-n-weak"
              />
              {{ t('CRM_KANBAN.AI_SETTINGS.HANDOFF.ENABLED') }}
            </label>

            <template v-if="defaultHandoff.enabled">
              <label class="flex items-center gap-2 text-xs text-n-slate-11">
                {{ t('CRM_KANBAN.HANDOFF_DRAWER.FLOW_MODE') }}
                <select
                  v-model="defaultHandoff.handoff_mode"
                  class="reset-base rounded-lg border-0 bg-n-surface-2 px-2 py-1 text-xs text-n-slate-12 outline outline-1 outline-n-weak"
                >
                  <option v-for="flow in FLOW_MODES" :key="flow" :value="flow">
                    {{
                      t(
                        `CRM_KANBAN.HANDOFF_DRAWER.FLOW_MODE_${flow.toUpperCase()}`
                      )
                    }}
                  </option>
                </select>
              </label>

              <textarea
                v-model="defaultHandoff.trigger"
                rows="2"
                class="reset-base w-full rounded-lg border-0 bg-n-surface-2 px-3 py-2 text-sm text-n-slate-12 outline outline-1 outline-n-weak"
                :placeholder="
                  t('CRM_KANBAN.AI_SETTINGS.HANDOFF.TRIGGER_PLACEHOLDER')
                "
              />

              <div class="flex flex-wrap items-center gap-4">
                <label class="flex items-center gap-2 text-xs text-n-slate-11">
                  {{ t('CRM_KANBAN.AI_SETTINGS.HANDOFF.MODE') }}
                  <select
                    v-model="defaultHandoff.mode"
                    class="reset-base rounded-lg border-0 bg-n-surface-2 px-2 py-1 text-xs text-n-slate-12 outline outline-1 outline-n-weak"
                  >
                    <option
                      v-for="mode in SELECTOR_MODES"
                      :key="mode"
                      :value="mode"
                    >
                      {{
                        t(
                          `CRM_KANBAN.AI_SETTINGS.HANDOFF.MODE_${mode.toUpperCase()}`
                        )
                      }}
                    </option>
                  </select>
                </label>
                <label class="flex items-center gap-2 text-xs text-n-slate-11">
                  <input
                    v-model="defaultHandoff.prefer_online"
                    type="checkbox"
                    class="rounded border-n-weak"
                  />
                  {{ t('CRM_KANBAN.AI_SETTINGS.HANDOFF.PREFER_ONLINE') }}
                </label>
              </div>

              <div
                v-if="defaultHandoff.handoff_mode === 'r3_invite'"
                class="flex flex-wrap items-center gap-4"
              >
                <label class="flex items-center gap-2 text-xs text-n-slate-11">
                  {{ t('CRM_KANBAN.HANDOFF_DRAWER.PICKUP_THRESHOLD_MINUTES') }}
                  <input
                    v-model="defaultPickupThresholdMinutes"
                    type="number"
                    min="1"
                    class="reset-base w-20 rounded-lg border-0 bg-n-surface-2 px-2 py-1 text-xs text-n-slate-12 outline outline-1 outline-n-weak"
                  />
                </label>
                <label class="flex items-center gap-2 text-xs text-n-slate-11">
                  {{ t('CRM_KANBAN.HANDOFF_DRAWER.ESCALATION_USER') }}
                  <select
                    v-model="defaultHandoff.escalation_user_id"
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
          </section>

          <section class="grid gap-3">
            <h3 class="mb-0 text-sm font-medium text-n-slate-12">
              {{ t('CRM_KANBAN.HANDOFF_DRAWER.STAGES_SECTION_TITLE') }}
            </h3>

            <div
              v-for="stage in namedStages()"
              :key="stage.id"
              class="grid gap-2 rounded-lg border border-n-weak bg-n-alpha-black2 p-3"
            >
              <div class="flex items-center justify-between gap-3">
                <span class="text-xs font-medium text-n-slate-12">
                  {{ stage.name }}
                </span>
                <div
                  class="flex shrink-0 items-center gap-1 rounded-lg bg-n-alpha-2 p-0.5"
                >
                  <button
                    type="button"
                    class="rounded-md px-2 py-1 text-xs"
                    :class="
                      !stageForms[stage.id]?.custom
                        ? 'bg-n-solid-3 text-n-slate-12'
                        : 'text-n-slate-11'
                    "
                    @click="stageForms[stage.id].custom = false"
                  >
                    {{ t('CRM_KANBAN.HANDOFF_DRAWER.USE_DEFAULT') }}
                  </button>
                  <button
                    type="button"
                    class="rounded-md px-2 py-1 text-xs"
                    :class="
                      stageForms[stage.id]?.custom
                        ? 'bg-n-solid-3 text-n-slate-12'
                        : 'text-n-slate-11'
                    "
                    @click="stageForms[stage.id].custom = true"
                  >
                    {{ t('CRM_KANBAN.HANDOFF_DRAWER.USE_CUSTOM') }}
                  </button>
                </div>
              </div>

              <p
                v-if="!stageForms[stage.id]?.custom"
                class="mb-0 text-xs leading-5 text-n-slate-11"
              >
                {{ inheritedSummary(stage.id) }}
              </p>

              <template v-else>
                <label class="flex items-center gap-2 text-xs text-n-slate-12">
                  <input
                    v-model="stageForms[stage.id].enabled"
                    type="checkbox"
                    class="rounded border-n-weak"
                  />
                  {{ t('CRM_KANBAN.AI_SETTINGS.HANDOFF.ENABLED') }}
                </label>

                <template v-if="stageForms[stage.id].enabled">
                  <label
                    class="flex items-center gap-2 text-xs text-n-slate-11"
                  >
                    {{ t('CRM_KANBAN.HANDOFF_DRAWER.FLOW_MODE') }}
                    <select
                      v-model="stageForms[stage.id].handoff_mode"
                      class="reset-base rounded-lg border-0 bg-n-surface-2 px-2 py-1 text-xs text-n-slate-12 outline outline-1 outline-n-weak"
                    >
                      <option
                        v-for="flow in FLOW_MODES"
                        :key="flow"
                        :value="flow"
                      >
                        {{
                          t(
                            `CRM_KANBAN.HANDOFF_DRAWER.FLOW_MODE_${flow.toUpperCase()}`
                          )
                        }}
                      </option>
                    </select>
                  </label>

                  <textarea
                    v-model="stageForms[stage.id].trigger"
                    rows="2"
                    class="reset-base w-full rounded-lg border-0 bg-n-surface-2 px-3 py-2 text-sm text-n-slate-12 outline outline-1 outline-n-weak"
                    :placeholder="
                      t('CRM_KANBAN.AI_SETTINGS.HANDOFF.TRIGGER_PLACEHOLDER')
                    "
                  />

                  <div class="flex flex-wrap items-center gap-4">
                    <label
                      class="flex items-center gap-2 text-xs text-n-slate-11"
                    >
                      {{ t('CRM_KANBAN.AI_SETTINGS.HANDOFF.MODE') }}
                      <select
                        v-model="stageForms[stage.id].mode"
                        class="reset-base rounded-lg border-0 bg-n-surface-2 px-2 py-1 text-xs text-n-slate-12 outline outline-1 outline-n-weak"
                      >
                        <option
                          v-for="mode in SELECTOR_MODES"
                          :key="mode"
                          :value="mode"
                        >
                          {{
                            t(
                              `CRM_KANBAN.AI_SETTINGS.HANDOFF.MODE_${mode.toUpperCase()}`
                            )
                          }}
                        </option>
                      </select>
                    </label>
                    <label
                      class="flex items-center gap-2 text-xs text-n-slate-11"
                    >
                      <input
                        v-model="stageForms[stage.id].prefer_online"
                        type="checkbox"
                        class="rounded border-n-weak"
                      />
                      {{ t('CRM_KANBAN.AI_SETTINGS.HANDOFF.PREFER_ONLINE') }}
                    </label>
                  </div>

                  <div
                    v-if="stageForms[stage.id].handoff_mode === 'r3_invite'"
                    class="flex flex-wrap items-center gap-4"
                  >
                    <label
                      class="flex items-center gap-2 text-xs text-n-slate-11"
                    >
                      {{
                        t('CRM_KANBAN.HANDOFF_DRAWER.PICKUP_THRESHOLD_MINUTES')
                      }}
                      <input
                        :value="pickupThresholdMinutes(stageForms[stage.id])"
                        type="number"
                        min="1"
                        class="reset-base w-20 rounded-lg border-0 bg-n-surface-2 px-2 py-1 text-xs text-n-slate-12 outline outline-1 outline-n-weak"
                        @input="
                          updatePickupThresholdMinutes(
                            stageForms[stage.id],
                            $event.target.value
                          )
                        "
                      />
                    </label>
                    <label
                      class="flex items-center gap-2 text-xs text-n-slate-11"
                    >
                      {{ t('CRM_KANBAN.HANDOFF_DRAWER.ESCALATION_USER') }}
                      <select
                        v-model="stageForms[stage.id].escalation_user_id"
                        class="reset-base max-w-52 rounded-lg border-0 bg-n-surface-2 px-2 py-1 text-xs text-n-slate-12 outline outline-1 outline-n-weak"
                      >
                        <option :value="null">
                          {{
                            t('CRM_KANBAN.HANDOFF_DRAWER.ESCALATION_USER_NONE')
                          }}
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
            </div>
          </section>
        </div>
      </div>

      <div
        class="flex items-center justify-end gap-2 border-t border-n-weak px-6 py-4"
      >
        <Button
          :label="t('CRM_KANBAN.PIPELINE_DRAWER.CANCEL')"
          slate
          faded
          @click="$emit('close')"
        />
        <Button
          :label="t('CRM_KANBAN.HANDOFF_DRAWER.SAVE')"
          icon="i-lucide-check"
          :is-loading="isSaving"
          :disabled="isLoading || loadFailed"
          @click="saveSettings"
        />
      </div>
    </div>
  </transition>
</template>
