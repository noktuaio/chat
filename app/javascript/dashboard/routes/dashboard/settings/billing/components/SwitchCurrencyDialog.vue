<script setup>
import { ref, computed } from 'vue';
import { useI18n } from 'vue-i18n';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import { getCurrencyConfig } from 'dashboard/constants/billing';

const props = defineProps({
  targetCurrency: {
    type: String,
    default: '',
  },
  isLoading: {
    type: Boolean,
    default: false,
  },
});

const emit = defineEmits(['confirm']);

const { t } = useI18n();

const dialogRef = ref(null);

const currencyLabel = computed(() =>
  t(getCurrencyConfig(props.targetCurrency).i18nLabelKey)
);

const open = () => dialogRef.value?.open();
const close = () => dialogRef.value?.close();

defineExpose({ open, close });
</script>

<template>
  <Dialog
    ref="dialogRef"
    type="alert"
    :title="$t('BILLING_SETTINGS.CURRENCY.CONFIRM.TITLE')"
    :description="
      $t('BILLING_SETTINGS.CURRENCY.CONFIRM.DESCRIPTION', {
        currency: currencyLabel,
      })
    "
    :confirm-button-label="
      $t('BILLING_SETTINGS.CURRENCY.CONFIRM.CONFIRM_BUTTON')
    "
    :cancel-button-label="$t('BILLING_SETTINGS.CURRENCY.CONFIRM.CANCEL_BUTTON')"
    :is-loading="isLoading"
    @confirm="emit('confirm')"
  >
    <div class="p-2.5 rounded-lg bg-n-amber-2 border border-n-amber-6">
      <p class="text-sm text-n-amber-11">
        {{ $t('BILLING_SETTINGS.CURRENCY.CONFIRM.WARNING') }}
      </p>
    </div>
  </Dialog>
</template>
