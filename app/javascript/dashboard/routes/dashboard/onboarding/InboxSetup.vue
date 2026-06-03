<script setup>
import { computed, onMounted, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRouter } from 'vue-router';
import { useStore, useMapGetter } from 'dashboard/composables/store';
import { useAlert, useTrack } from 'dashboard/composables';
import { useAccount } from 'dashboard/composables/useAccount';
import { useConfig } from 'dashboard/composables/useConfig';
import { useHelpCenterGenerationStore } from 'dashboard/stores/helpCenterGeneration';
import { ONBOARDING_EVENTS } from 'dashboard/helper/AnalyticsHelper/events';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import OnboardingLayout from './shared/OnboardingLayout.vue';
import OnboardingSection from './shared/OnboardingSection.vue';
import InboxChannelsDialog from './inbox-setup/InboxChannelsDialog.vue';
import InboxChannelsFooter from './inbox-setup/InboxChannelsFooter.vue';
import ChannelRow from './inbox-setup/ChannelRow.vue';
import WebWidgetCreationStatus from './inbox-setup/WebWidgetCreationStatus.vue';
import HelpCenterCreationStatus from './inbox-setup/HelpCenterCreationStatus.vue';
import { useChannelConnect } from './inbox-setup/useChannelConnect';
import { useDetectedChannels } from './inbox-setup/useDetectedChannels';

const { t } = useI18n();
const store = useStore();
const router = useRouter();
const { accountId, currentAccount, finishOnboarding } = useAccount();
const { isEnterprise } = useConfig();
const { connectViaOAuth, connectWhatsapp } = useChannelConnect();

const helpCenterGenerationId = computed(
  () => currentAccount.value?.custom_attributes?.help_center_generation_id
);

const isSubmitting = ref(false);

const integrations = useMapGetter('integrations/getAppIntegrations');
const inboxes = useMapGetter('inboxes/getInboxes');

const FEATURED_APP_IDS = ['slack', 'linear'];

const featuredApps = computed(() =>
  FEATURED_APP_IDS.map(id =>
    integrations.value.find(item => item.id === id)
  ).filter(Boolean)
);

const { displayedChannels, remainingChannels, connectedInbox } =
  useDetectedChannels();

const channelsDialogRef = ref(null);

onMounted(() => {
  store.dispatch('integrations/get');
  store.dispatch('inboxes/get');
  useHelpCenterGenerationStore().hydrate(helpCenterGenerationId.value);
  useTrack(ONBOARDING_EVENTS.INBOX_SETUP_VISITED);
});

const completeOnboarding = async event => {
  if (isSubmitting.value) return;

  isSubmitting.value = true;
  try {
    // Declare the step we're completing so the controller only clears it when
    // the stored step still matches (idempotent). setUser then refreshes the
    // auth store so the router guard sees the cleared step and lets us in.
    await finishOnboarding({ onboarding_step: 'inbox_setup' });
    useTrack(event);
    await store.dispatch('setUser');
    router.push({ name: 'home', params: { accountId: accountId.value } });
  } catch {
    useAlert(t('ONBOARDING_INBOX_SETUP.ERROR'));
  } finally {
    isSubmitting.value = false;
  }
};

const handleContinue = () =>
  completeOnboarding(ONBOARDING_EVENTS.INBOX_SETUP_COMPLETED);
const handleSkip = () =>
  completeOnboarding(ONBOARDING_EVENTS.INBOX_SETUP_SKIPPED);
const openChannelsDialog = () => channelsDialogRef.value?.open();
const refetchInboxes = () => store.dispatch('inboxes/get');

// WhatsApp connects via Meta's embedded-signup popup; Facebook (page picker)
// and the credential-form channels (Telegram, Line) open the channels dialog
// preselected to their in-dialog step; the rest go through the redirect OAuth
// flow (Gmail/Outlook keyed by email provider, Instagram by channel type).
const DIALOG_CHANNELS = ['facebook', 'telegram', 'line'];

const connectChannel = channel => {
  if (channel.type === 'whatsapp') {
    connectWhatsapp();
    return;
  }
  if (DIALOG_CHANNELS.includes(channel.type)) {
    channelsDialogRef.value?.open(channel.type);
    return;
  }
  connectViaOAuth(channel.inbox?.provider || channel.type);
};
</script>

<template>
  <OnboardingLayout
    :greeting="t('ONBOARDING_INBOX_SETUP.GREETING')"
    :subtitle="t('ONBOARDING_INBOX_SETUP.SUBTITLE')"
    :continue-label="t('ONBOARDING_INBOX_SETUP.CONTINUE')"
    :skip-label="t('ONBOARDING_INBOX_SETUP.SKIP')"
    :is-loading="isSubmitting"
    @continue="handleContinue"
    @skip="handleSkip"
  >
    <template #greeting-icon>
      <Icon icon="i-lucide-wrench" class="size-4 text-n-slate-7" />
    </template>

    <OnboardingSection
      :title="t('ONBOARDING_INBOX_SETUP.CREATED_FOR_YOU.TITLE')"
      icon="i-lucide-sparkles"
    >
      <WebWidgetCreationStatus />
      <HelpCenterCreationStatus v-if="isEnterprise && helpCenterGenerationId" />
    </OnboardingSection>

    <OnboardingSection
      :title="t('ONBOARDING_INBOX_SETUP.CHANNELS.TITLE')"
      icon="i-lucide-inbox"
    >
      <ChannelRow
        v-for="channel in displayedChannels"
        :key="channel.type"
        :channel="channel"
        :connected-inbox="connectedInbox(channel)"
        @connect="connectChannel"
      />
      <InboxChannelsFooter
        :remaining-channels="remainingChannels"
        @view-all="openChannelsDialog"
      />
    </OnboardingSection>

    <!-- Disabled for this phase; integrations will be implemented later. -->
    <!-- TODO: Delete this and associated code for adding it later -->
    <OnboardingSection
      v-if="false"
      :title="t('ONBOARDING_INBOX_SETUP.APPS.TITLE')"
      icon="i-lucide-blocks"
      bare
    >
      <div class="grid grid-cols-2 gap-3">
        <div
          v-for="app in featuredApps"
          :key="app.id"
          class="border border-n-weak rounded-xl bg-n-surface-1 p-3 flex flex-col gap-2"
        >
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-2">
              <img
                :src="`/dashboard/images/integrations/${app.id}.png`"
                :alt="app.name"
                class="size-5 object-contain block dark:hidden"
              />
              <img
                :src="`/dashboard/images/integrations/${app.id}-dark.png`"
                :alt="app.name"
                class="size-5 object-contain hidden dark:block"
              />
              <span class="text-sm font-medium text-n-slate-12">
                {{ app.name }}
              </span>
            </div>
            <span v-if="app.enabled" class="text-sm text-n-slate-11">
              {{ t('INTEGRATION_APPS.STATUS.ENABLED') }}
            </span>
            <button
              v-else
              type="button"
              class="text-sm font-medium text-n-blue-11 hover:underline"
            >
              {{ t('INTEGRATION_APPS.CONFIGURE') }}
            </button>
          </div>
          <p class="text-xs leading-relaxed text-n-slate-11">
            {{ app.description }}
          </p>
        </div>
      </div>
    </OnboardingSection>
  </OnboardingLayout>
  <InboxChannelsDialog
    ref="channelsDialogRef"
    :inboxes="inboxes"
    @connected="refetchInboxes"
  />
</template>
