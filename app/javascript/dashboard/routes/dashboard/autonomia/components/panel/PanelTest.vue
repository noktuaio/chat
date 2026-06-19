<script setup>
import { ref, computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { useStore } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';

import NextButton from 'dashboard/components-next/button/Button.vue';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import Accordion from 'dashboard/components-next/Accordion/Accordion.vue';
import ChatBubble from '../builder/ChatBubble.vue';
import ChatComposer from '../builder/ChatComposer.vue';
import { useAutoScroll } from '../../composables/useAutoScroll.js';

// Sandbox to chat with the agent before/while it is live. Reuses the same chat
// primitives as the Builder (ChatBubble + ChatComposer + useAutoScroll) so the
// three PO bugs are fixed in one place: the composer auto-grows, every token
// adapts to dark mode, and the log auto-scrolls so the input is never covered.
// The assistant turn additionally renders confidence, handoff and the cited
// knowledge below its bubble (without breaking when knowledge is empty).
const props = defineProps({
  agentId: {
    type: Number,
    required: true,
  },
});

const { t } = useI18n();
const store = useStore();

// #3 INSTRUÇÃO VIVA (C): a guided agent only has an instruction once the build
// closes. The panel page already loaded the record via `autonomiaAgents/show`,
// which carries the safe `has_instruction` boolean (never the text). Warn when
// the agent isn't finalized so the user isn't silently testing an empty draft.
const agent = computed(() =>
  store.getters['autonomiaAgents/getRecord'](props.agentId)
);
const agentNotFinalized = computed(
  () => agent.value?.has_instruction === false
);

// The test conversation is volatile (cleared on tab switch). Persist it in
// sessionStorage per agent so switching panels and back doesn't wipe the chat.
const storageKey = `autonomia_test_v2_${props.agentId}`;
const restoreMessages = () => {
  try {
    const raw = sessionStorage.getItem(storageKey);
    return raw ? JSON.parse(raw) : [];
  } catch (error) {
    return [];
  }
};

const messages = ref(restoreMessages());
const isSending = ref(false);
const scrollRef = ref(null);

const persistMessages = () => {
  try {
    sessionStorage.setItem(storageKey, JSON.stringify(messages.value));
  } catch (error) {
    // sessionStorage may be unavailable (private mode/quota); ignore.
  }
};

useAutoScroll(scrollRef, () => [messages.value.length, isSending.value]);

// handoff.reason is an allowlisted code — map it to a friendly label so raw
// codes never leak to the user. Reuses the PERFORMANCE reason labels.
const REASON_LABEL_KEYS = {
  low_confidence: 'AGENTS.PERFORMANCE.REASONS.CODES.low_confidence',
  ai_unavailable: 'AGENTS.PERFORMANCE.REASONS.CODES.ai_unavailable',
  human_requested: 'AGENTS.PERFORMANCE.REASONS.CODES.human_requested',
  missing_knowledge: 'AGENTS.PERFORMANCE.REASONS.CODES.missing_knowledge',
  policy: 'AGENTS.PERFORMANCE.REASONS.CODES.policy',
  other: 'AGENTS.PERFORMANCE.REASONS.OTHER',
};
const reasonLabel = reason =>
  t(REASON_LABEL_KEYS[reason] ?? 'AGENTS.PERFORMANCE.REASONS.OTHER');

// The backend test endpoint takes the prior turns as { role, content }.
const history = computed(() =>
  messages.value.map(message => ({
    role: message.role,
    content: message.content,
  }))
);

const confidenceClass = confidence => {
  if (confidence >= 0.7) return 'bg-n-teal-9';
  if (confidence >= 0.4) return 'bg-n-amber-9';
  return 'bg-n-ruby-9';
};

const prettyJson = value => {
  if (value === undefined || value === null) return '';
  try {
    return JSON.stringify(value, null, 2);
  } catch (error) {
    return String(value);
  }
};

const promptRequestConfig = prompt => {
  if (!prompt) return null;
  return {
    model: prompt.model,
    reasoning_effort: prompt.reasoning_effort,
    tools: prompt.tools || [],
    schema: prompt.schema,
  };
};

const resetConversation = () => {
  messages.value = [];
  persistMessages();
};

// Reuse the Materiais upload pipeline so files dropped via the composer clip
// become agent knowledge (same identity as the Construtor's attachFromChat).
const isAttaching = computed(
  () => !!store.getters['autonomiaSources/getUIFlags']?.creatingItem
);

const onAttach = async ({ files }) => {
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

// Read a File into a base64 data-url (the exact `input_image` shape the model
// consumes). The test path is synchronous, so images travel inline in the POST
// (no ActiveStorage round-trip). History stays text-only: images are read only
// in the turn they are attached.
const fileToDataUrl = file =>
  new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result);
    reader.onerror = reject;
    reader.readAsDataURL(file);
  });

const sleep = ms =>
  new Promise(resolve => {
    setTimeout(resolve, ms);
  });

// Push the assistant turn. When the backend returns the humanized `chunks`
// (same ReplyChunker the live channel uses), PLAY them like the real delivery:
// the "typing" bubble shows during each chunk's delay, then the chunk lands as
// its own bubble. The confidence/handoff/knowledge meta renders only under the
// LAST bubble (`meta: true`); intermediate chunks are plain bubbles. Without
// chunks (handoff / humanize off) it falls back to a single bubble.
const pushAssistantTurn = async data => {
  const meta = {
    confidence: data.confidence,
    handoff: data.handoff,
    usedKnowledge: data.used_knowledge || [],
    prompt: data.prompt || null,
    meta: true,
  };

  if (data.humanized && Array.isArray(data.chunks) && data.chunks.length) {
    for (let i = 0; i < data.chunks.length; i += 1) {
      const chunk = data.chunks[i];
      isSending.value = true; // typing bubble during the pause
      // eslint-disable-next-line no-await-in-loop
      await sleep(Math.max(0, Number(chunk.delay_ms) || 0));
      isSending.value = false;
      const isLast = i === data.chunks.length - 1;
      messages.value.push({
        role: 'assistant',
        content: chunk.text,
        ...(isLast ? meta : {}),
      });
      persistMessages();
    }
    return;
  }

  messages.value.push({ role: 'assistant', content: data.reply, ...meta });
  persistMessages();
};

const onSend = async ({ content, images = [] }) => {
  if (isSending.value) return;

  messages.value.push({ role: 'user', content });
  persistMessages();

  try {
    isSending.value = true;
    const imageDataUrls = await Promise.all(images.map(fileToDataUrl));
    const data = await store.dispatch('autonomiaAgents/test', {
      agentId: props.agentId,
      message: content,
      history: history.value,
      images: imageDataUrls,
    });
    await pushAssistantTurn(data);
  } catch (error) {
    useAlert(t('AGENTS.TEST.ERROR'));
  } finally {
    isSending.value = false;
  }
};
</script>

<template>
  <div class="flex flex-col w-full h-full max-w-3xl gap-4 px-6 py-6 mx-auto">
    <div class="flex items-center justify-between flex-shrink-0 gap-3">
      <p class="flex items-center gap-2 text-sm text-n-slate-11">
        <Icon icon="i-lucide-flask-conical" class="text-n-slate-10" />
        {{ t('AGENTS.TEST.DESCRIPTION') }}
      </p>
      <NextButton
        ghost
        sm
        slate
        icon="i-lucide-rotate-ccw"
        :label="t('AGENTS.TEST.RESET')"
        @click="resetConversation"
      />
    </div>

    <div
      v-if="agentNotFinalized"
      role="status"
      class="flex items-start gap-2 px-4 py-3 text-xs rounded-lg bg-n-amber-9/10 text-n-amber-11 shrink-0"
    >
      <Icon icon="i-lucide-triangle-alert" class="mt-0.5 shrink-0" />
      <span>{{ t('AGENTS.TEST.NOT_FINALIZED') }}</span>
    </div>

    <!-- LAYOUT CONTRACT: the log is flex-1/min-h-0/overflow + the composer is a
         shrink-0 sibling in the same flex-col, so the input is never covered. -->
    <div class="flex flex-col flex-1 min-h-0 gap-3">
      <div
        ref="scrollRef"
        role="log"
        aria-live="polite"
        :aria-label="t('AGENTS.TEST.CONVERSATION')"
        class="flex flex-col flex-1 min-h-0 gap-5 p-4 overflow-y-auto border rounded-xl border-n-weak bg-n-solid-1"
      >
        <div
          v-if="!messages.length"
          class="flex flex-col items-center justify-center flex-1 gap-2 text-center text-n-slate-10"
        >
          <Icon icon="i-lucide-sparkles" class="text-2xl" />
          <p class="text-sm">{{ t('AGENTS.TEST.EMPTY') }}</p>
        </div>

        <template v-for="(message, index) in messages" :key="index">
          <ChatBubble :role="message.role" :content="message.content" />

          <div
            v-if="message.role === 'assistant' && message.meta"
            class="flex flex-col gap-2 pl-8"
          >
            <div class="flex items-center gap-2">
              <span class="text-xs text-n-slate-11">
                {{ t('AGENTS.TEST.CONFIDENCE') }}
              </span>
              <div
                class="w-20 h-1.5 overflow-hidden rounded-full bg-n-alpha-2"
                role="progressbar"
                :aria-valuenow="Math.round((message.confidence || 0) * 100)"
                aria-valuemin="0"
                aria-valuemax="100"
                :aria-label="t('AGENTS.TEST.CONFIDENCE')"
              >
                <div
                  class="h-full rounded-full"
                  :class="confidenceClass(message.confidence)"
                  :style="{
                    width: `${Math.round((message.confidence || 0) * 100)}%`,
                  }"
                />
              </div>
              <span class="text-xs tabular-nums text-n-slate-11">
                {{ `${Math.round((message.confidence || 0) * 100)}%` }}
              </span>
            </div>

            <div
              v-if="message.handoff && message.handoff.should"
              class="flex items-start gap-2 px-3 py-2 text-xs rounded-lg bg-n-amber-9/10 text-n-amber-11"
            >
              <Icon icon="i-lucide-user-round" class="flex-shrink-0 mt-0.5" />
              <span>
                {{
                  t('AGENTS.TEST.HANDOFF_NOTICE', {
                    reason: reasonLabel(message.handoff.reason),
                  })
                }}
              </span>
            </div>

            <Accordion
              v-if="message.usedKnowledge && message.usedKnowledge.length"
              :title="
                t('AGENTS.TEST.KNOWLEDGE_USED', {
                  count: message.usedKnowledge.length,
                })
              "
            >
              <ul class="flex flex-col gap-2">
                <li
                  v-for="(item, kIndex) in message.usedKnowledge"
                  :key="kIndex"
                  class="flex flex-col gap-0.5"
                >
                  <span class="text-xs font-medium text-n-slate-12">
                    {{ t('AGENTS.TEST.SOURCE', { source: item.source }) }}
                  </span>
                  <span class="text-xs text-n-slate-11 line-clamp-3">
                    {{ item.content }}
                  </span>
                </li>
              </ul>
            </Accordion>

            <Accordion
              v-if="message.prompt"
              :title="t('AGENTS.TEST.PROMPT_USED')"
            >
              <div class="flex flex-col gap-3">
                <section class="flex flex-col gap-1">
                  <span class="text-xs font-medium text-n-slate-12">
                    {{ t('AGENTS.TEST.PROMPT_INSTRUCTIONS') }}
                  </span>
                  <pre
                    class="max-h-72 overflow-auto whitespace-pre-wrap break-words rounded-lg border border-n-weak bg-n-alpha-1 p-3 text-[11px] leading-relaxed text-n-slate-11"
                  ><code>{{ message.prompt.instructions }}</code></pre>
                </section>

                <section class="flex flex-col gap-1">
                  <span class="text-xs font-medium text-n-slate-12">
                    {{ t('AGENTS.TEST.PROMPT_INPUT') }}
                  </span>
                  <pre
                    class="max-h-72 overflow-auto whitespace-pre-wrap break-words rounded-lg border border-n-weak bg-n-alpha-1 p-3 text-[11px] leading-relaxed text-n-slate-11"
                  ><code>{{ prettyJson(message.prompt.input) }}</code></pre>
                </section>

                <section class="flex flex-col gap-1">
                  <span class="text-xs font-medium text-n-slate-12">
                    {{ t('AGENTS.TEST.PROMPT_REQUEST') }}
                  </span>
                  <pre
                    class="max-h-72 overflow-auto whitespace-pre-wrap break-words rounded-lg border border-n-weak bg-n-alpha-1 p-3 text-[11px] leading-relaxed text-n-slate-11"
                  ><code>{{
                    prettyJson(promptRequestConfig(message.prompt))
                  }}</code></pre>
                </section>
              </div>
            </Accordion>
          </div>
        </template>

        <ChatBubble v-if="isSending" role="assistant" thinking />
      </div>

      <div class="shrink-0">
        <ChatComposer
          :placeholder="t('AGENTS.TEST.PLACEHOLDER')"
          :is-sending="isSending"
          can-attach
          :is-attaching="isAttaching"
          @send="onSend"
          @attach="onAttach"
        />
      </div>
    </div>
  </div>
</template>
