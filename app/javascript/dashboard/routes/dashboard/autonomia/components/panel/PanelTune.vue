<script setup>
import { ref, reactive, computed, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useStore, useMapGetter } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import AutonomiaBuilderImagesAPI from 'dashboard/api/autonomia/builderImages';

import NextButton from 'dashboard/components-next/button/Button.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import Select from 'dashboard/components-next/select/Select.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import BuilderChat from '../builder/BuilderChat.vue';

const props = defineProps({
  agent: {
    type: Object,
    required: true,
  },
  agentId: {
    type: Number,
    required: true,
  },
});

const { t } = useI18n();
const store = useStore();

// Build-thread store powers the guided re-conversation (IP OCULTO: only
// human-facing turns; instruction/scaffold are never read here).
const builderMessages = useMapGetter('autonomiaBuildThreads/getMessages');
const builderStatus = useMapGetter('autonomiaBuildThreads/getStatus');
const builderPhase = useMapGetter('autonomiaBuildThreads/getPhase');
const builderUiFlags = useMapGetter('autonomiaBuildThreads/getUIFlags');

const reconverseDialogRef = ref(null);

const advancedMode = ref(props.agent.mode === 'manual');

const TONE_OPTIONS = computed(() =>
  ['friendly', 'professional', 'neutral', 'playful'].map(value => ({
    value,
    label: t(`AGENTS.TUNE.TONE_OPTIONS.${value.toUpperCase()}`),
  }))
);

const HANDOFF_OPTIONS = computed(() =>
  ['none', 'inbox_member'].map(value => ({
    value,
    label: t(`AGENTS.TUNE.HANDOFF_OPTIONS.${value.toUpperCase()}`),
  }))
);

const VALID_HANDOFF_STRATEGIES = new Set(['none', 'inbox_member']);

const normalizeHandoffStrategy = value =>
  VALID_HANDOFF_STRATEGIES.has(value) ? value : 'none';

// handoff_strategy/confidence_threshold are jsonb `config` store-accessors on
// the backend — read them from agent.config, never the top level.
const form = reactive({
  greeting: props.agent.greeting || '',
  fallback_message: props.agent.fallback_message || '',
  tone: props.agent.tone || 'friendly',
  handoff_strategy: normalizeHandoffStrategy(
    props.agent.config?.handoff_strategy
  ),
  confidence_threshold:
    props.agent.config?.confidence_threshold != null
      ? props.agent.config.confidence_threshold
      : 0.6,
  instruction: props.agent.instruction || '',
});

watch(
  () => props.agent,
  agent => {
    form.greeting = agent.greeting || '';
    form.fallback_message = agent.fallback_message || '';
    form.tone = agent.tone || 'friendly';
    form.handoff_strategy = normalizeHandoffStrategy(
      agent.config?.handoff_strategy
    );
    form.confidence_threshold =
      agent.config?.confidence_threshold != null
        ? agent.config.confidence_threshold
        : 0.6;
    form.instruction = agent.instruction || '';
    advancedMode.value = agent.mode === 'manual';
  }
);

const isSaving = computed(
  () => store.getters['autonomiaAgents/getUIFlags'].updatingItem
);

// handoff_strategy/confidence_threshold MUST be nested under `config` — the
// controller's strong params only permit `config: {}` for these virtuals and
// would silently drop them at the top level.
// Always stamp the current `mode` so saving the simple block never drops the
// advanced/manual toggle silently. `extra` may still override (manual save).
const buildPayload = (extra = {}) => ({
  id: props.agentId,
  greeting: form.greeting,
  fallback_message: form.fallback_message,
  tone: form.tone,
  mode: advancedMode.value ? 'manual' : 'guided',
  config: {
    handoff_strategy: form.handoff_strategy,
    confidence_threshold: Number(form.confidence_threshold),
  },
  ...extra,
});

const saveSettings = async (extra = {}) => {
  try {
    await store.dispatch('autonomiaAgents/update', buildPayload(extra));
    useAlert(t('AGENTS.TUNE.SAVE_SUCCESS'));
  } catch (error) {
    useAlert(t('AGENTS.TUNE.SAVE_ERROR'));
  }
};

// Never overwrite the instruction with an empty string (a guided serializer may
// omit `instruction`, leaving the textarea blank). `mode` is already carried by
// buildPayload, so only `instruction` needs to be passed here.
const saveManualInstruction = () => {
  if (!form.instruction.trim()) {
    useAlert(t('AGENTS.TUNE.EMPTY_INSTRUCTION'));
    return;
  }
  saveSettings({ instruction: form.instruction });
};

// Guided re-tuning reuses the Builder conversation. The thread is created
// lazily on the first refinement message (the backend rejects empty opens), so
// opening the dialog only clears any prior thread.
const openReconverse = () => {
  store.commit('autonomiaBuildThreads/RESET');
  reconverseDialogRef.value?.open();
};

// MULTIMODAL (async): identical to the Construtor — upload each attached image
// to ActiveStorage and pass the `signed_id`s on the turn so the Builder reads
// them inline in the job. Pure-text turns skip the upload (images empty).
const uploadImages = async images => {
  if (!images?.length) return [];
  const results = await Promise.all(
    images.map(file => AutonomiaBuilderImagesAPI.upload(file))
  );
  return results.map(({ data }) => data.signed_id);
};

const onReconverseSend = async ({ content, images = [] }) => {
  const threadId = store.getters['autonomiaBuildThreads/getThread']?.id;
  try {
    const imageSignedIds = await uploadImages(images);
    if (!threadId) {
      await store.dispatch('autonomiaBuildThreads/start', {
        agentId: props.agentId,
        type: props.agent.agent_type,
        message: content,
        image_signed_ids: imageSignedIds,
      });
      return;
    }
    await store.dispatch('autonomiaBuildThreads/send', {
      threadId,
      content,
      extra: { image_signed_ids: imageSignedIds },
    });
  } catch (error) {
    useAlert(t('AGENTS.BUILDER.SEND_ERROR'));
  }
};

// Re-conversation composer gains the clip (parity with the Construtor): files
// land as agent knowledge via the same Materiais pipeline. The agent always
// exists here, so no NEED_START guard is required.
const isAttaching = computed(
  () => !!store.getters['autonomiaSources/getUIFlags']?.creatingItem
);

const onReconverseAttach = async ({ files }) => {
  if (!files?.length) return;
  await Promise.all(
    files.map(file =>
      store
        .dispatch('autonomiaSources/create', {
          agentId: props.agentId,
          descriptor: { file, kind: 'knowledge' },
        })
        .catch(() => useAlert(t('AGENTS.MATERIALS.UPLOAD_ERROR')))
    )
  );
  useAlert(t('AGENTS.BUILDER.ATTACH.ATTACHED'));
};

const onReconverseClose = () => {
  store.dispatch('autonomiaBuildThreads/stopPolling');
  store.commit('autonomiaBuildThreads/RESET');
};

// When the guided re-conversation actually regenerates the agent (phase becomes
// 'reviewing'), refresh it, notify the user and close the dialog so the new
// human_card is visible. `status === 'ready'` is ambiguous (ready + needs_more_info)
// and would close the dialog mid-conversation.
watch(builderPhase, phase => {
  if (phase === 'reviewing') {
    store.dispatch('autonomiaAgents/show', props.agentId);
    reconverseDialogRef.value?.close();
    useAlert(t('AGENTS.TUNE.SAVE_SUCCESS'));
  }
});
</script>

<template>
  <div class="flex flex-col w-full h-full max-w-3xl gap-8 px-6 py-6 mx-auto">
    <!-- Mode toggle: guided (default) vs advanced/manual -->
    <div class="flex items-center justify-between">
      <div class="flex flex-col">
        <h2 class="text-sm font-medium text-n-slate-12">
          {{ t('AGENTS.TUNE.MODE_TITLE') }}
        </h2>
        <p class="text-xs text-n-slate-10">
          {{ t('AGENTS.TUNE.ADVANCED_HINT') }}
        </p>
      </div>
      <div class="flex items-center gap-2">
        <span class="text-xs text-n-slate-11">{{
          t('AGENTS.TUNE.ADVANCED')
        }}</span>
        <Switch
          v-model="advancedMode"
          :aria-label="t('AGENTS.TUNE.ADVANCED')"
        />
      </div>
    </div>

    <!-- GUIDED: human card + re-conversar. IP OCULTO: never shows instruction. -->
    <section v-if="!advancedMode" class="flex flex-col gap-4">
      <h3 class="text-sm font-medium text-n-slate-12">
        {{ t('AGENTS.TUNE.GUIDED') }}
      </h3>
      <div
        class="flex flex-col gap-2 px-4 py-4 border rounded-xl border-n-iris-4 bg-n-iris-2"
      >
        <span
          class="flex items-center gap-1.5 text-xs font-medium tracking-wide uppercase text-n-iris-11"
        >
          <Icon icon="i-lucide-sparkles" class="size-3.5" />
          {{ t('AGENTS.TUNE.CURRENT_CARD') }}
        </span>
        <p class="text-sm leading-relaxed text-n-slate-12">
          {{ agent.human_card || t('AGENTS.TUNE.NO_CARD') }}
        </p>
      </div>
      <NextButton
        outline
        sm
        icon="i-lucide-sparkles"
        :label="t('AGENTS.TUNE.RECONVERSE')"
        class="w-fit"
        @click="openReconverse"
      />
    </section>

    <!-- ADVANCED / MANUAL: visible instruction textarea. -->
    <section v-else class="flex flex-col gap-3">
      <h3 class="text-sm font-medium text-n-slate-12">
        {{ t('AGENTS.TUNE.ADVANCED') }}
      </h3>
      <div
        class="flex items-start gap-2 px-4 py-3 text-xs rounded-lg bg-n-amber-9/10 text-n-amber-11"
      >
        <Icon icon="i-lucide-shield" class="flex-shrink-0 mt-0.5" />
        <span>{{ t('AGENTS.TUNE.MANUAL_WARNING') }}</span>
      </div>
      <TextArea
        v-model="form.instruction"
        :label="t('AGENTS.TUNE.INSTRUCTION_LABEL')"
        :placeholder="t('AGENTS.TUNE.INSTRUCTION_PLACEHOLDER')"
        auto-height
        min-height="10rem"
        max-height="24rem"
      />
      <NextButton
        solid
        sm
        :label="t('AGENTS.TUNE.SAVE_INSTRUCTION')"
        :is-loading="isSaving"
        :disabled="!form.instruction.trim() || isSaving"
        class="w-fit"
        @click="saveManualInstruction"
      />
    </section>

    <!-- Simple adjustments: always visible in both modes. -->
    <section class="flex flex-col gap-4 pt-2 border-t border-n-weak">
      <h3 class="text-sm font-medium text-n-slate-12">
        {{ t('AGENTS.TUNE.SIMPLE_TITLE') }}
      </h3>

      <Input
        v-model="form.greeting"
        :label="t('AGENTS.TUNE.GREETING')"
        :placeholder="t('AGENTS.TUNE.GREETING_PLACEHOLDER')"
      />
      <Input
        v-model="form.fallback_message"
        :label="t('AGENTS.TUNE.FALLBACK')"
        :placeholder="t('AGENTS.TUNE.FALLBACK_PLACEHOLDER')"
      />

      <div class="flex flex-col gap-1">
        <label class="text-sm font-medium text-n-slate-12">
          {{ t('AGENTS.TUNE.TONE') }}
        </label>
        <Select v-model="form.tone" :options="TONE_OPTIONS" class="w-full" />
      </div>

      <div class="flex flex-col gap-1">
        <label class="text-sm font-medium text-n-slate-12">
          {{ t('AGENTS.TUNE.HANDOFF_STRATEGY') }}
        </label>
        <Select
          v-model="form.handoff_strategy"
          :options="HANDOFF_OPTIONS"
          class="w-full"
        />
        <p class="text-xs leading-relaxed text-n-slate-10">
          {{ t('AGENTS.TUNE.HANDOFF_HINT') }}
        </p>
      </div>

      <div class="flex flex-col gap-1">
        <div class="flex items-center justify-between">
          <label class="text-sm font-medium text-n-slate-12">
            {{ t('AGENTS.TUNE.CONFIDENCE_THRESHOLD') }}
          </label>
          <span class="text-xs tabular-nums text-n-slate-11">
            {{ `${Math.round(Number(form.confidence_threshold) * 100)}%` }}
          </span>
        </div>
        <input
          v-model="form.confidence_threshold"
          type="range"
          min="0"
          max="1"
          step="0.05"
          class="w-full accent-n-brand"
          :aria-label="t('AGENTS.TUNE.CONFIDENCE_THRESHOLD')"
          :aria-valuetext="`${Math.round(Number(form.confidence_threshold) * 100)}%`"
        />
      </div>

      <NextButton
        solid
        sm
        :label="t('AGENTS.TUNE.SAVE')"
        :is-loading="isSaving"
        class="w-fit"
        @click="saveSettings()"
      />
    </section>

    <!-- Guided re-conversation dialog (reuses the Builder chat). -->
    <Dialog
      ref="reconverseDialogRef"
      :title="t('AGENTS.TUNE.RECONVERSE_TITLE')"
      width="2xl"
      :show-confirm-button="false"
      :cancel-button-label="t('AGENTS.TUNE.RECONVERSE_CLOSE')"
      @close="onReconverseClose"
    >
      <div class="h-[28rem]">
        <BuilderChat
          :messages="builderMessages"
          :is-sending="
            builderUiFlags.sending ||
            builderUiFlags.creating ||
            builderStatus === 'processing'
          "
          :disabled="builderPhase === 'reviewing'"
          can-attach
          :is-attaching="isAttaching"
          @send="onReconverseSend"
          @attach="onReconverseAttach"
        />
      </div>
    </Dialog>
  </div>
</template>
