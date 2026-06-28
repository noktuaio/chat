<script setup>
import { computed, onMounted, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useLocale } from 'shared/composables/useLocale';
import { useEmitter } from 'dashboard/composables/emitter';
import { BUS_EVENTS } from 'shared/constants/busEvents';
import CrmAiUsageAPI from 'dashboard/api/crmAiUsage';

import Button from 'dashboard/components-next/button/Button.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import ReportMetricCard from 'dashboard/routes/dashboard/settings/reports/components/ReportMetricCard.vue';
import BarChart from 'shared/components/charts/BarChart.vue';

const { t } = useI18n();
const { resolvedLocale } = useLocale();

const PERIODS = [
  { key: 'TODAY', days: 0, groupBy: 'hour' },
  { key: 'WEEK', days: 7, groupBy: 'day' },
  { key: 'MONTH', days: 30, groupBy: 'day' },
];

const PERIOD_SPEND_LABEL_KEYS = {
  TODAY: 'CRM_AI_USAGE.KPI.SPEND_BY_PERIOD.TODAY',
  WEEK: 'CRM_AI_USAGE.KPI.SPEND_BY_PERIOD.WEEK',
  MONTH: 'CRM_AI_USAGE.KPI.SPEND_BY_PERIOD.MONTH',
};

const PERIOD_SERIES_LABEL_KEYS = {
  TODAY: 'CRM_AI_USAGE.SECTIONS.SPEND_BY_PERIOD.TODAY',
  WEEK: 'CRM_AI_USAGE.SECTIONS.SPEND_BY_PERIOD.WEEK',
  MONTH: 'CRM_AI_USAGE.SECTIONS.SPEND_BY_PERIOD.MONTH',
};

const WIDTH_CLASSES = [
  'w-0',
  'w-[5%]',
  'w-[10%]',
  'w-[15%]',
  'w-[20%]',
  'w-[25%]',
  'w-[30%]',
  'w-[35%]',
  'w-[40%]',
  'w-[45%]',
  'w-[50%]',
  'w-[55%]',
  'w-[60%]',
  'w-[65%]',
  'w-[70%]',
  'w-[75%]',
  'w-[80%]',
  'w-[85%]',
  'w-[90%]',
  'w-[95%]',
  'w-full',
];

const selectedPeriodKey = ref('WEEK');
const payload = ref(null);
const isLoading = ref(true);
const loadError = ref(false);
const isExporting = ref(false);

const selectedPeriod = computed(
  () =>
    PERIODS.find(period => period.key === selectedPeriodKey.value) || PERIODS[1]
);

const periodStart = computed(() => {
  const since = new Date();
  if (selectedPeriod.value.key === 'TODAY') {
    since.setHours(0, 0, 0, 0);
    return since;
  }
  since.setDate(since.getDate() - selectedPeriod.value.days);
  return since;
});

const requestParams = computed(() => ({
  since: periodStart.value.toISOString(),
  until: new Date().toISOString(),
  group_by: selectedPeriod.value.groupBy,
}));

const totals = computed(() => payload.value?.totals || {});
const exchangeRate = computed(() => payload.value?.exchange_rate || {});
const rateUnavailable = computed(
  () => exchangeRate.value.rate_unavailable === true
);
const spendByResource = computed(() => payload.value?.spend_by_resource || []);
const historyRows = computed(() => payload.value?.history?.rows || []);
const timeSeries = computed(() => payload.value?.time_series || []);

const formatNumber = value =>
  new Intl.NumberFormat(resolvedLocale.value).format(Number(value || 0));

const formatMoney = (value, currency = 'BRL') =>
  new Intl.NumberFormat(resolvedLocale.value, {
    style: 'currency',
    currency,
  }).format(Number(value || 0));

const formatMoneyPayload = value => {
  if (!value) return formatMoney(0);
  if (value.rate_unavailable || value.cost_brl == null) {
    return formatMoney(value.cost_usd, 'USD');
  }
  return formatMoney(value.cost_brl, 'BRL');
};

const formatDateTime = value => {
  if (!value) return '—';
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return '—';
  return new Intl.DateTimeFormat(resolvedLocale.value, {
    dateStyle: 'medium',
    timeStyle: 'short',
  }).format(date);
};

const formatBucket = value => {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  if (selectedPeriod.value.groupBy === 'hour') {
    return new Intl.DateTimeFormat(resolvedLocale.value, {
      hour: '2-digit',
      minute: '2-digit',
    }).format(date);
  }
  return new Intl.DateTimeFormat(resolvedLocale.value, {
    day: '2-digit',
    month: 'short',
  }).format(date);
};

const formatTokens = row => formatNumber(row?.total_tokens || 0);

const moneyForDelta = delta => {
  const costUsd = Number(delta?.cost_usd || 0);
  const rate = exchangeRate.value.rate;
  if (!rateUnavailable.value && rate) {
    return { cost_usd: costUsd, cost_brl: costUsd * Number(rate) };
  }
  return { cost_usd: costUsd, cost_brl: null, rate_unavailable: true };
};

const addMoney = (left = {}, right = {}) => ({
  cost_usd: Number(left.cost_usd || 0) + Number(right.cost_usd || 0),
  cost_brl:
    left.cost_brl == null || right.cost_brl == null
      ? null
      : Number(left.cost_brl || 0) + Number(right.cost_brl || 0),
  rate_unavailable: left.rate_unavailable || right.rate_unavailable,
});

const maxResourceSpend = computed(() =>
  Math.max(0, ...spendByResource.value.map(row => Number(row.cost_usd || 0)))
);

const widthClass = percentage => {
  if (!percentage) return WIDTH_CLASSES[0];
  const index = Math.max(1, Math.min(20, Math.ceil(percentage / 5)));
  return WIDTH_CLASSES[index];
};

const resourceRows = computed(() =>
  spendByResource.value.map(row => ({
    ...row,
    widthClass: widthClass(
      (Number(row.cost_usd || 0) / maxResourceSpend.value) * 100
    ),
  }))
);

const hasResourceSpend = computed(() =>
  spendByResource.value.some(row => Number(row.cost_usd || 0) > 0)
);

const chartMoneyKey = computed(() =>
  rateUnavailable.value ? 'cost_usd' : 'cost_brl'
);
const periodSpendLabel = computed(() => {
  // eslint-disable-next-line @intlify/vue-i18n/no-dynamic-keys
  return t(PERIOD_SPEND_LABEL_KEYS[selectedPeriod.value.key]);
});
const periodSeriesLabel = computed(() => {
  // eslint-disable-next-line @intlify/vue-i18n/no-dynamic-keys
  return t(PERIOD_SERIES_LABEL_KEYS[selectedPeriod.value.key]);
});

const weeklySpendCollection = computed(() => ({
  labels: timeSeries.value.map(point => formatBucket(point.timestamp)),
  datasets: [
    {
      label: periodSeriesLabel.value,
      backgroundColor: '#2563eb',
      data: timeSeries.value.map(point =>
        Number(point[chartMoneyKey.value] || point.cost_usd || 0)
      ),
    },
  ],
}));

const hasTimeSeries = computed(() =>
  timeSeries.value.some(point => Number(point.cost_usd || 0) > 0)
);

const topCards = computed(() => [
  {
    key: 'SPEND',
    label: periodSpendLabel.value,
    value: formatMoneyPayload(totals.value.period_spend),
    infoText: t('CRM_AI_USAGE.KPI.SPEND_INFO'),
  },
  {
    key: 'USAGE',
    label: t('CRM_AI_USAGE.KPI.USAGE'),
    value: formatNumber(totals.value.usage_count),
    infoText: t('CRM_AI_USAGE.KPI.USAGE_INFO'),
  },
  {
    key: 'SAVINGS',
    label: t('CRM_AI_USAGE.KPI.SAVINGS'),
    value: formatMoneyPayload(totals.value.cache_savings),
    infoText: t('CRM_AI_USAGE.KPI.SAVINGS_INFO', {
      percentage: totals.value.cache_savings_pct || 0,
    }),
  },
  {
    key: 'AVERAGE',
    label: t('CRM_AI_USAGE.KPI.AVERAGE'),
    value: formatMoneyPayload(totals.value.average_cost),
    infoText: t('CRM_AI_USAGE.KPI.AVERAGE_INFO'),
  },
]);

const fetchUsage = async () => {
  isLoading.value = true;
  loadError.value = false;
  try {
    const { data } = await CrmAiUsageAPI.get(requestParams.value);
    payload.value = data.payload;
  } catch (error) {
    loadError.value = true;
  } finally {
    isLoading.value = false;
  }
};

const exportCsv = async () => {
  isExporting.value = true;
  try {
    const { data } = await CrmAiUsageAPI.export({
      ...requestParams.value,
      export_format: 'csv',
    });
    const url = URL.createObjectURL(data);
    const link = document.createElement('a');
    link.setAttribute('href', url);
    link.setAttribute('download', 'crm-ai-usage-report.csv');
    link.click();
    URL.revokeObjectURL(url);
  } finally {
    isExporting.value = false;
  }
};

const applyDeltaToTotals = delta => {
  const currentTotals = totals.value;
  const usageCount = Number(currentTotals.usage_count || 0) + 1;
  const periodSpend = addMoney(
    currentTotals.period_spend,
    moneyForDelta(delta)
  );
  payload.value.totals = {
    ...currentTotals,
    usage_count: usageCount,
    period_spend: periodSpend,
    average_cost: {
      cost_usd: periodSpend.cost_usd / usageCount,
      cost_brl:
        periodSpend.cost_brl == null ? null : periodSpend.cost_brl / usageCount,
      rate_unavailable: periodSpend.rate_unavailable,
    },
  };
};

const applyDeltaToResource = delta => {
  const money = moneyForDelta(delta);
  const resource = delta.resource || t('CRM_AI_USAGE.RESOURCE_FALLBACK');
  const rows = [...spendByResource.value];
  const index = rows.findIndex(row => row.resource === resource);
  const base =
    index >= 0
      ? rows[index]
      : {
          resource,
          usage_count: 0,
          input_tokens: 0,
          cached_tokens: 0,
          output_tokens: 0,
          cost_usd: 0,
          cost_brl: rateUnavailable.value ? null : 0,
        };
  const updated = {
    ...base,
    usage_count: Number(base.usage_count || 0) + 1,
    input_tokens:
      Number(base.input_tokens || 0) + Number(delta.input_tokens || 0),
    cached_tokens:
      Number(base.cached_tokens || 0) + Number(delta.cached_tokens || 0),
    output_tokens:
      Number(base.output_tokens || 0) + Number(delta.output_tokens || 0),
    cost_usd: Number(base.cost_usd || 0) + money.cost_usd,
    cost_brl:
      base.cost_brl == null || money.cost_brl == null
        ? null
        : Number(base.cost_brl || 0) + money.cost_brl,
    rate_unavailable: base.rate_unavailable || money.rate_unavailable,
  };

  if (index >= 0) {
    rows.splice(index, 1, updated);
  } else {
    rows.push(updated);
  }
  payload.value.spend_by_resource = rows.sort(
    (left, right) => Number(right.cost_usd || 0) - Number(left.cost_usd || 0)
  );
};

const seriesBucketTimestamp = value => {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  if (selectedPeriod.value.groupBy === 'hour') {
    date.setMinutes(0, 0, 0);
  } else {
    date.setHours(0, 0, 0, 0);
  }
  return date.toISOString();
};

const applyDeltaToSeries = delta => {
  const money = moneyForDelta(delta);
  const timestamp = seriesBucketTimestamp(delta.created_at);
  const series = [...timeSeries.value];
  const index = series.findIndex(point => point.timestamp === timestamp);
  const base =
    index >= 0
      ? series[index]
      : {
          timestamp,
          cost_usd: 0,
          cost_brl: rateUnavailable.value ? null : 0,
        };
  const updated = addMoney(base, money);

  if (index >= 0) {
    series.splice(index, 1, { ...base, ...updated });
  } else {
    series.push({ timestamp, ...updated });
  }
  payload.value.time_series = series.sort(
    (left, right) => new Date(left.timestamp) - new Date(right.timestamp)
  );
};

const applyDeltaToHistory = delta => {
  const rows = historyRows.value.filter(row => row.id !== delta.id);
  rows.unshift({
    id: delta.id,
    created_at: delta.created_at,
    resource: delta.resource || t('CRM_AI_USAGE.RESOURCE_FALLBACK'),
    account: payload.value.account,
    input_tokens: delta.input_tokens,
    cached_tokens: delta.cached_tokens,
    output_tokens: delta.output_tokens,
    total_tokens: delta.total_tokens,
    ...moneyForDelta(delta),
  });

  payload.value.history = {
    ...(payload.value.history || {}),
    total_count: Number(payload.value.history?.total_count || 0) + 1,
    rows: rows.slice(0, payload.value.history?.per_page || 25),
  };
};

const applyRealtimeUsage = delta => {
  if (!payload.value || isLoading.value) return;

  const createdAt = new Date(delta?.created_at);
  if (Number.isNaN(createdAt.getTime()) || createdAt < periodStart.value)
    return;

  applyDeltaToTotals(delta);
  applyDeltaToResource(delta);
  applyDeltaToSeries(delta);
  applyDeltaToHistory(delta);
};

watch(selectedPeriodKey, fetchUsage);

useEmitter(BUS_EVENTS.CRM_AI_USAGE_CREATED, applyRealtimeUsage);

onMounted(fetchUsage);
</script>

<template>
  <div class="flex flex-col w-full h-full overflow-auto bg-n-background">
    <header
      class="flex flex-col gap-4 px-6 py-5 border-b sm:flex-row sm:items-center sm:justify-between border-n-weak"
    >
      <div class="min-w-0">
        <div class="flex items-center gap-2 mb-1">
          <h1 class="m-0 text-xl font-semibold text-n-slate-12">
            {{ t('CRM_AI_USAGE.HEADER.TITLE') }}
          </h1>
          <span
            class="px-2 py-0.5 text-xs font-medium rounded-full bg-n-teal-3 text-n-teal-11"
          >
            {{ t('CRM_AI_USAGE.HEADER.LIVE') }}
          </span>
        </div>
        <p class="m-0 text-sm text-n-slate-11">
          {{ t('CRM_AI_USAGE.HEADER.DESCRIPTION') }}
        </p>
      </div>

      <div class="flex flex-wrap items-center gap-3">
        <div
          class="flex items-center h-9 p-1 border rounded-lg border-n-weak bg-n-alpha-black2"
          role="group"
          :aria-label="t('CRM_AI_USAGE.PERIOD_LABEL')"
        >
          <button
            v-for="period in PERIODS"
            :key="period.key"
            type="button"
            class="h-7 px-3 text-sm rounded-md text-n-slate-11"
            :class="
              selectedPeriodKey === period.key
                ? 'bg-n-solid-1 text-n-slate-12 shadow-sm'
                : 'hover:bg-n-alpha-2'
            "
            @click="selectedPeriodKey = period.key"
          >
            {{ t(`CRM_AI_USAGE.PERIOD.${period.key}`) }}
          </button>
        </div>
        <Button
          :label="t('CRM_AI_USAGE.ACTIONS.DOWNLOAD')"
          icon="i-lucide-download"
          slate
          faded
          sm
          :is-loading="isExporting"
          @click="exportCsv"
        />
      </div>
    </header>

    <div
      v-if="isLoading && !payload"
      class="flex flex-col items-center justify-center flex-1 gap-3 text-n-slate-11"
    >
      <Spinner />
      <span class="text-sm">{{ t('CRM_AI_USAGE.LOADING') }}</span>
    </div>

    <div
      v-else-if="loadError"
      class="flex flex-col items-center justify-center flex-1 gap-3 text-n-slate-11"
    >
      <span class="text-sm">{{ t('CRM_AI_USAGE.ERROR') }}</span>
      <Button :label="t('CRM_AI_USAGE.ACTIONS.RETRY')" sm @click="fetchUsage" />
    </div>

    <div v-else class="flex flex-col gap-6 p-6">
      <p
        v-if="rateUnavailable"
        class="px-3 py-2 m-0 text-sm border rounded-lg border-n-amber-5 bg-n-amber-2 text-n-amber-11"
      >
        {{ t('CRM_AI_USAGE.RATE_UNAVAILABLE') }}
      </p>

      <div class="grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-4">
        <div
          v-for="card in topCards"
          :key="card.key"
          class="p-4 border rounded-xl border-n-weak bg-n-solid-1"
        >
          <ReportMetricCard
            :label="card.label"
            :value="card.value"
            :info-text="card.infoText"
          />
        </div>
      </div>

      <div class="grid grid-cols-1 gap-6 lg:grid-cols-2">
        <section class="p-5 border rounded-xl border-n-weak bg-n-solid-1">
          <h2 class="mb-4 text-sm font-medium text-n-slate-12">
            {{ t('CRM_AI_USAGE.SECTIONS.SPEND_BY_RESOURCE') }}
          </h2>
          <p v-if="!hasResourceSpend" class="m-0 text-sm text-n-slate-11">
            {{ t('CRM_AI_USAGE.EMPTY.RESOURCE') }}
          </p>
          <div v-else class="flex flex-col gap-3" data-test-id="resource-bars">
            <div
              v-for="resource in resourceRows"
              :key="resource.resource"
              class="grid items-center grid-cols-[minmax(0,11rem)_minmax(0,1fr)_5rem] gap-3"
            >
              <span class="text-sm truncate text-n-slate-11">
                {{ resource.resource }}
              </span>
              <div
                class="h-5 overflow-hidden rounded-md bg-n-alpha-black2"
                :aria-label="resource.resource"
              >
                <div
                  class="h-full rounded-md bg-n-blue-9"
                  :class="resource.widthClass"
                />
              </div>
              <span class="text-sm font-medium text-right text-n-slate-12">
                {{ formatMoneyPayload(resource) }}
              </span>
            </div>
          </div>
        </section>

        <section class="p-5 border rounded-xl border-n-weak bg-n-solid-1">
          <h2 class="mb-4 text-sm font-medium text-n-slate-12">
            {{ periodSeriesLabel }}
          </h2>
          <p v-if="!hasTimeSeries" class="m-0 text-sm text-n-slate-11">
            {{ t('CRM_AI_USAGE.EMPTY.SERIES') }}
          </p>
          <div v-else class="h-64">
            <BarChart :collection="weeklySpendCollection" />
          </div>
        </section>
      </div>

      <section
        class="overflow-hidden border rounded-xl border-n-weak bg-n-solid-1"
      >
        <div class="flex flex-col gap-1 p-5 border-b border-n-weak">
          <h2 class="m-0 text-sm font-medium text-n-slate-12">
            {{ t('CRM_AI_USAGE.SECTIONS.HISTORY') }}
          </h2>
          <p class="m-0 text-sm text-n-slate-11">
            {{ t('CRM_AI_USAGE.TABLE_NOTICE') }}
          </p>
        </div>
        <div class="overflow-x-auto">
          <table class="min-w-full text-sm">
            <thead class="bg-n-alpha-black2 text-n-slate-11">
              <tr>
                <th class="px-5 py-3 font-medium text-left">
                  {{ t('CRM_AI_USAGE.TABLE.WHEN') }}
                </th>
                <th class="px-5 py-3 font-medium text-left">
                  {{ t('CRM_AI_USAGE.TABLE.RESOURCE') }}
                </th>
                <th class="px-5 py-3 font-medium text-left">
                  {{ t('CRM_AI_USAGE.TABLE.ACCOUNT') }}
                </th>
                <th class="px-5 py-3 font-medium text-right">
                  {{ t('CRM_AI_USAGE.TABLE.TOKENS') }}
                </th>
                <th class="px-5 py-3 font-medium text-right">
                  {{ t('CRM_AI_USAGE.TABLE.COST') }}
                </th>
              </tr>
            </thead>
            <tbody>
              <tr v-if="!historyRows.length">
                <td colspan="5" class="px-5 py-8 text-center text-n-slate-11">
                  {{ t('CRM_AI_USAGE.EMPTY.HISTORY') }}
                </td>
              </tr>
              <tr
                v-for="row in historyRows"
                :key="row.id"
                class="border-t border-n-weak"
              >
                <td class="px-5 py-3 text-n-slate-11">
                  {{ formatDateTime(row.created_at) }}
                </td>
                <td class="px-5 py-3 font-medium text-n-slate-12">
                  {{ row.resource }}
                </td>
                <td class="px-5 py-3 text-n-slate-11">
                  {{ row.account?.name || '—' }}
                </td>
                <td class="px-5 py-3 text-right text-n-slate-11">
                  {{ formatTokens(row) }}
                </td>
                <td class="px-5 py-3 font-medium text-right text-n-slate-12">
                  {{ formatMoneyPayload(row) }}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <p class="m-0 text-sm text-center text-n-slate-11">
        {{ t('CRM_AI_USAGE.PRIVACY_FOOTER') }}
      </p>
    </div>
  </div>
</template>
