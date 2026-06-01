<script setup>
import { computed, onMounted, reactive, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute, useRouter } from 'vue-router';
import { useStore, useStoreGetters } from 'dashboard/composables/store';

import Button from 'dashboard/components-next/button/Button.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import Breadcrumb from 'dashboard/components-next/breadcrumb/Breadcrumb.vue';
import CampaignsAPI from 'dashboard/api/campaigns';

const { t } = useI18n();
const route = useRoute();
const router = useRouter();
const store = useStore();
const getters = useStoreGetters();

const state = reactive({
  metrics: null,
  contacts: [],
  meta: {},
  status: 'all',
  page: 1,
  isFetchingMetrics: false,
  isFetchingContacts: false,
});

const campaignId = computed(() => Number(route.params.campaignId));
const campaign = computed(() =>
  getters['campaigns/getAllCampaigns'].value.find(
    record => Number(record.id) === campaignId.value
  )
);
const campaignTitle = computed(
  () => campaign.value?.title || `#${campaignId.value}`
);

const breadcrumbItems = computed(() => [
  { label: t('CAMPAIGN.WHATSAPP.ANALYTICS.BREADCRUMB.CAMPAIGNS') },
  { label: t('CAMPAIGN.WHATSAPP.ANALYTICS.BREADCRUMB.WHATSAPP') },
  { label: campaignTitle.value },
]);

const statusOptions = computed(() => [
  { key: 'all', label: t('CAMPAIGN.WHATSAPP.ANALYTICS.FILTERS.ALL') },
  { key: 'sent', label: t('CAMPAIGN.WHATSAPP.ANALYTICS.METRICS.SENT') },
  {
    key: 'delivered',
    label: t('CAMPAIGN.WHATSAPP.ANALYTICS.METRICS.DELIVERED'),
  },
  { key: 'read', label: t('CAMPAIGN.WHATSAPP.ANALYTICS.METRICS.READ') },
  { key: 'failed', label: t('CAMPAIGN.WHATSAPP.ANALYTICS.METRICS.FAILED') },
  { key: 'skipped', label: t('CAMPAIGN.WHATSAPP.ANALYTICS.METRICS.SKIPPED') },
]);

const metricItems = computed(() => [
  {
    key: 'audience',
    label: t('CAMPAIGN.WHATSAPP.ANALYTICS.METRICS.AUDIENCE'),
    showRate: false,
  },
  {
    key: 'sent',
    label: t('CAMPAIGN.WHATSAPP.ANALYTICS.METRICS.SENT'),
    showRate: true,
  },
  {
    key: 'delivered',
    label: t('CAMPAIGN.WHATSAPP.ANALYTICS.METRICS.DELIVERED'),
    showRate: true,
  },
  {
    key: 'read',
    label: t('CAMPAIGN.WHATSAPP.ANALYTICS.METRICS.READ'),
    showRate: true,
  },
  {
    key: 'failed',
    label: t('CAMPAIGN.WHATSAPP.ANALYTICS.METRICS.FAILED'),
    showRate: true,
  },
  {
    key: 'skipped',
    label: t('CAMPAIGN.WHATSAPP.ANALYTICS.METRICS.SKIPPED'),
    showRate: true,
  },
]);

const hasNextPage = computed(() => state.page < Number(state.meta.total_pages));
const hasPreviousPage = computed(() => state.page > 1);
const audienceCount = computed(() => Number(state.metrics?.audience || 0));

const insightSummary = computed(() =>
  t('CAMPAIGN.WHATSAPP.ANALYTICS.SUMMARY', {
    delivered: state.metrics?.delivered || 0,
    audience: audienceCount.value,
    skipped: state.metrics?.skipped || 0,
    failed: state.metrics?.failed || 0,
  })
);

const filterLabel = option => {
  const count =
    option.key === 'all'
      ? audienceCount.value
      : Number(state.metrics?.[option.key] || 0);

  return `${option.label} ${count}`;
};

const metricRate = key => {
  if (!audienceCount.value) return '0%';

  return `${Math.round((Number(state.metrics?.[key] || 0) / audienceCount.value) * 100)}%`;
};

const fetchMetrics = async () => {
  state.isFetchingMetrics = true;
  try {
    const response = await CampaignsAPI.analyticsMetrics(campaignId.value);
    state.metrics = response.data;
  } finally {
    state.isFetchingMetrics = false;
  }
};

const fetchContacts = async () => {
  state.isFetchingContacts = true;
  try {
    const response = await CampaignsAPI.analyticsContacts(campaignId.value, {
      status: state.status === 'all' ? undefined : state.status,
      page: state.page,
    });
    state.contacts = response.data.payload;
    state.meta = response.data.meta;
  } finally {
    state.isFetchingContacts = false;
  }
};

const setStatus = status => {
  state.status = status;
  state.page = 1;
};

const goToPreviousPage = () => {
  if (!hasPreviousPage.value) return;
  state.page -= 1;
};

const goToNextPage = () => {
  if (!hasNextPage.value) return;
  state.page += 1;
};

const statusLabel = status =>
  statusOptions.value.find(option => option.key === status)?.label || status;

const errorReason = delivery =>
  delivery.error_message || delivery.error_title || delivery.error_code || '-';

const messageContent = delivery => {
  if (delivery.message_content) return delivery.message_content;
  if (delivery.status === 'skipped') {
    return t('CAMPAIGN.WHATSAPP.ANALYTICS.TABLE.MESSAGE_NOT_GENERATED');
  }

  return '-';
};

const emptyStateMessage = computed(() => {
  if (state.status === 'all') return t('CAMPAIGN.WHATSAPP.ANALYTICS.EMPTY');

  return t('CAMPAIGN.WHATSAPP.ANALYTICS.EMPTY_FILTER', {
    status: statusLabel(state.status).toLowerCase(),
  });
});

const statusBadgeClass = status =>
  ({
    sent: 'bg-n-blue-3 text-n-blue-11',
    delivered: 'bg-n-teal-3 text-n-teal-11',
    read: 'bg-n-iris-3 text-n-iris-11',
    failed: 'bg-n-ruby-3 text-n-ruby-11',
    skipped: 'bg-n-amber-3 text-n-amber-11',
  })[status] || 'bg-n-slate-3 text-n-slate-11';

const goBack = () => {
  router.push({ name: 'campaigns_whatsapp_index' });
};

const handleBreadcrumbClick = () => {
  goBack();
};

onMounted(() => {
  store.dispatch('campaigns/get');
  fetchMetrics();
  fetchContacts();
});

watch(
  () => [state.status, state.page],
  () => fetchContacts()
);
</script>

<template>
  <section class="flex h-full flex-col overflow-hidden bg-n-surface-1">
    <header class="sticky top-0 z-10 px-6">
      <div class="mx-auto w-full max-w-7xl">
        <div class="flex w-full items-center py-7">
          <Breadcrumb :items="breadcrumbItems" @click="handleBreadcrumbClick" />
        </div>
      </div>
    </header>

    <main class="flex-1 overflow-y-auto px-6">
      <div class="mx-auto w-full max-w-7xl py-4">
        <div class="mb-6 min-w-0">
          <h1 class="text-heading-1 text-n-slate-12">
            {{ t('CAMPAIGN.WHATSAPP.ANALYTICS.TITLE') }}
          </h1>
          <p class="mt-1 truncate text-sm text-n-slate-11">
            {{ campaignTitle }}
            <span
              v-if="campaign?.inbox?.name"
              class="before:mx-1 before:text-n-slate-10 before:content-['·']"
            >
              {{ campaign.inbox.name }}
            </span>
          </p>
        </div>

        <div
          v-if="state.isFetchingMetrics"
          class="flex h-24 items-center justify-center text-n-slate-11"
        >
          <Spinner />
        </div>
        <div v-else class="grid grid-cols-2 gap-3 md:grid-cols-6">
          <div
            v-for="item in metricItems"
            :key="item.key"
            class="rounded-lg border border-n-weak bg-n-alpha-2 p-4"
          >
            <div class="text-sm font-medium text-n-slate-11">
              {{ item.label }}
            </div>
            <div class="mt-3 text-2xl font-semibold text-n-slate-12">
              {{ state.metrics?.[item.key] || 0 }}
            </div>
            <div
              v-if="item.showRate"
              class="mt-1 text-xs font-medium text-n-slate-10"
            >
              {{
                t('CAMPAIGN.WHATSAPP.ANALYTICS.RATE', {
                  value: metricRate(item.key),
                })
              }}
            </div>
          </div>
        </div>

        <div
          v-if="state.metrics"
          class="mt-4 rounded-lg border border-n-weak bg-n-alpha-1 px-4 py-3 text-sm text-n-slate-11"
        >
          {{ insightSummary }}
        </div>

        <div class="mt-6 flex flex-wrap gap-2">
          <Button
            v-for="option in statusOptions"
            :key="option.key"
            size="sm"
            :variant="state.status === option.key ? 'solid' : 'faded'"
            :color="state.status === option.key ? 'blue' : 'slate'"
            :label="filterLabel(option)"
            @click="setStatus(option.key)"
          />
        </div>

        <div class="mt-4 overflow-hidden rounded-lg border border-n-weak">
          <table class="w-full table-fixed text-left text-sm">
            <thead class="bg-n-alpha-2 text-xs font-medium text-n-slate-11">
              <tr>
                <th class="w-[15%] px-4 py-3">
                  {{ t('CAMPAIGN.WHATSAPP.ANALYTICS.TABLE.CONTACT') }}
                </th>
                <th class="w-[14%] px-4 py-3">
                  {{ t('CAMPAIGN.WHATSAPP.ANALYTICS.TABLE.PHONE_NUMBER') }}
                </th>
                <th class="w-[10%] px-4 py-3">
                  {{ t('CAMPAIGN.WHATSAPP.ANALYTICS.TABLE.STATUS') }}
                </th>
                <th class="w-[43%] px-4 py-3">
                  {{ t('CAMPAIGN.WHATSAPP.ANALYTICS.TABLE.MESSAGE') }}
                </th>
                <th class="w-[18%] px-4 py-3">
                  {{ t('CAMPAIGN.WHATSAPP.ANALYTICS.TABLE.ERROR_REASON') }}
                </th>
              </tr>
            </thead>
            <tbody class="divide-y divide-n-weak text-n-slate-12">
              <tr v-if="state.isFetchingContacts">
                <td colspan="5" class="h-24 text-center text-n-slate-11">
                  <Spinner />
                </td>
              </tr>
              <tr v-else-if="state.contacts.length === 0">
                <td colspan="5" class="px-4 py-8 text-center text-n-slate-11">
                  {{ emptyStateMessage }}
                </td>
              </tr>
              <template v-else>
                <tr
                  v-for="delivery in state.contacts"
                  :key="delivery.contact.id"
                >
                  <td class="break-words px-4 py-4 align-top">
                    {{ delivery.contact.name || '-' }}
                  </td>
                  <td class="break-words px-4 py-4 align-top">
                    {{ delivery.contact.phone_number || '-' }}
                  </td>
                  <td class="px-4 py-4 align-top">
                    <span
                      class="inline-flex h-6 items-center rounded-md px-2 text-xs font-medium capitalize"
                      :class="statusBadgeClass(delivery.status)"
                    >
                      {{ statusLabel(delivery.status) }}
                    </span>
                  </td>
                  <td
                    class="whitespace-pre-wrap break-words px-4 py-4 align-top text-n-slate-11"
                    :class="{
                      'italic text-n-slate-10': !delivery.message_content,
                    }"
                  >
                    {{ messageContent(delivery) }}
                  </td>
                  <td
                    class="whitespace-pre-wrap break-words px-4 py-4 align-top text-n-slate-11"
                  >
                    {{ errorReason(delivery) }}
                  </td>
                </tr>
              </template>
            </tbody>
          </table>
        </div>

        <div class="mt-4 flex items-center justify-between gap-3">
          <span class="text-sm text-n-slate-11">
            {{
              t('CAMPAIGN.WHATSAPP.ANALYTICS.PAGE_INFO', {
                current: state.meta.current_page || 1,
                total: state.meta.total_pages || 1,
              })
            }}
          </span>
          <div class="flex gap-2">
            <Button
              size="sm"
              color="slate"
              variant="faded"
              icon="i-lucide-chevron-left"
              :disabled="!hasPreviousPage"
              @click="goToPreviousPage"
            />
            <Button
              size="sm"
              color="slate"
              variant="faded"
              icon="i-lucide-chevron-right"
              :disabled="!hasNextPage"
              @click="goToNextPage"
            />
          </div>
        </div>
      </div>
    </main>
  </section>
</template>
