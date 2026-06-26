<script setup>
import { ref, computed } from 'vue';
import { useStore, useMapGetter } from 'dashboard/composables/store';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { useVuelidate } from '@vuelidate/core';
import { required, email } from '@vuelidate/validators';
import Button from 'dashboard/components-next/button/Button.vue';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import CrmScheduleEditor from 'dashboard/routes/dashboard/crm/components/sla/CrmScheduleEditor.vue';
import { copyTextToClipboard } from 'shared/helpers/clipboard';

const emit = defineEmits(['close']);

const store = useStore();
const { t } = useI18n();

const agentName = ref('');
const agentEmail = ref('');
const selectedRoleId = ref('agent');

const rules = {
  agentName: { required },
  agentEmail: { required, email },
  selectedRoleId: { required },
};

const v$ = useVuelidate(rules, {
  agentName,
  agentEmail,
  selectedRoleId,
});

const uiFlags = useMapGetter('agents/getUIFlags');
const getCustomRoles = useMapGetter('customRole/getCustomRoles');
const accountId = useMapGetter('getCurrentAccountId');
const isFeatureEnabledonAccount = useMapGetter(
  'accounts/isFeatureEnabledonAccount'
);

// SLA service-hours calendar (CRM SLA v2): visible only when the CRM fork is
// enabled AND the account has the enterprise `sla` feature. The schedule needs
// the created user as owner, so the editor opens right after a successful save.
const showSlaSchedule = computed(
  () =>
    window.globalConfig?.CRM_KANBAN_ENABLED === 'true' &&
    isFeatureEnabledonAccount.value(accountId.value, FEATURE_FLAGS.SLA)
);
const defineSchedule = ref(false);
const createdAgent = ref(null);
const showScheduleEditor = ref(false);
const manualInvitation = ref(null);

const finishAndClose = () => {
  showScheduleEditor.value = false;
  emit('close');
};

const shouldShowManualInvitation = invitation =>
  invitation?.pending_invitation && invitation?.invitation_url;

const copyManualInvitation = async () => {
  try {
    await copyTextToClipboard(manualInvitation.value?.invitation_url);
    useAlert(t('AGENT_MGMT.ADD.MANUAL_INVITATION.COPY_SUCCESS'));
  } catch {
    useAlert(t('AGENT_MGMT.ADD.MANUAL_INVITATION.COPY_ERROR'));
  }
};

const roles = computed(() => {
  const defaultRoles = [
    {
      id: 'administrator',
      name: 'administrator',
      label: t('AGENT_MGMT.AGENT_TYPES.ADMINISTRATOR'),
    },
    {
      id: 'agent',
      name: 'agent',
      label: t('AGENT_MGMT.AGENT_TYPES.AGENT'),
    },
  ];

  const customRoles = getCustomRoles.value.map(role => ({
    id: role.id,
    name: `custom_${role.id}`,
    label: role.name,
  }));

  return [...defaultRoles, ...customRoles];
});

const selectedRole = computed(() =>
  roles.value.find(
    role =>
      role.id === selectedRoleId.value || role.name === selectedRoleId.value
  )
);

const addAgent = async () => {
  v$.value.$touch();
  if (v$.value.$invalid) return;
  manualInvitation.value = null;

  try {
    const payload = {
      name: agentName.value,
      email: agentEmail.value,
    };

    if (selectedRole.value.name.startsWith('custom_')) {
      payload.custom_role_id = selectedRole.value.id;
    } else {
      payload.role = selectedRole.value.name;
    }

    const newAgent = await store.dispatch('agents/create', payload);
    if (shouldShowManualInvitation(newAgent)) {
      manualInvitation.value = newAgent;
      useAlert(t('AGENT_MGMT.ADD.API.INVITATION_MANUAL_SHARE'));
      return;
    }

    useAlert(
      newAgent?.pending_invitation
        ? t('AGENT_MGMT.ADD.API.INVITATION_SENT')
        : t('AGENT_MGMT.ADD.API.SUCCESS_MESSAGE')
    );
    if (showSlaSchedule.value && defineSchedule.value && newAgent?.id) {
      createdAgent.value = newAgent;
      showScheduleEditor.value = true;
      return;
    }
    emit('close');
  } catch (error) {
    const {
      response: {
        data: {
          error: errorResponse = '',
          attributes: attributes = [],
          message: attrError = '',
        } = {},
      } = {},
    } = error;

    let errorMessage = '';
    if (error?.response?.status === 422 && !attributes.includes('base')) {
      errorMessage = t('AGENT_MGMT.ADD.API.EXIST_MESSAGE');
    } else {
      errorMessage = t('AGENT_MGMT.ADD.API.ERROR_MESSAGE');
    }
    useAlert(errorResponse || attrError || errorMessage);
  }
};
</script>

<template>
  <div class="flex flex-col h-auto overflow-auto">
    <woot-modal-header
      :header-title="$t('AGENT_MGMT.ADD.TITLE')"
      :header-content="$t('AGENT_MGMT.ADD.DESC')"
    />
    <form class="flex flex-col items-start w-full" @submit.prevent="addAgent">
      <div class="w-full">
        <label :class="{ error: v$.agentName.$error }">
          {{ $t('AGENT_MGMT.ADD.FORM.NAME.LABEL') }}
          <input
            v-model="agentName"
            type="text"
            :placeholder="$t('AGENT_MGMT.ADD.FORM.NAME.PLACEHOLDER')"
            @input="v$.agentName.$touch"
          />
        </label>
      </div>

      <div class="w-full">
        <label :class="{ error: v$.selectedRoleId.$error }">
          {{ $t('AGENT_MGMT.ADD.FORM.AGENT_TYPE.LABEL') }}
          <select v-model="selectedRoleId" @change="v$.selectedRoleId.$touch">
            <option v-for="role in roles" :key="role.id" :value="role.id">
              {{ role.label }}
            </option>
          </select>
          <span v-if="v$.selectedRoleId.$error" class="message">
            {{ $t('AGENT_MGMT.ADD.FORM.AGENT_TYPE.ERROR') }}
          </span>
        </label>
      </div>

      <div class="w-full">
        <label :class="{ error: v$.agentEmail.$error }">
          {{ $t('AGENT_MGMT.ADD.FORM.EMAIL.LABEL') }}
          <input
            v-model="agentEmail"
            type="email"
            :placeholder="$t('AGENT_MGMT.ADD.FORM.EMAIL.PLACEHOLDER')"
            @input="v$.agentEmail.$touch"
          />
        </label>
      </div>

      <div
        v-if="manualInvitation"
        class="w-full p-3 my-2 border rounded-lg border-n-amber-5 bg-n-amber-2 text-n-slate-12"
      >
        <p class="mb-1 text-sm font-medium">
          {{ $t('AGENT_MGMT.ADD.MANUAL_INVITATION.TITLE') }}
        </p>
        <p class="mb-3 text-sm text-n-slate-11">
          {{ $t('AGENT_MGMT.ADD.MANUAL_INVITATION.DESC') }}
        </p>
        <div class="flex items-center gap-2">
          <input
            readonly
            class="flex-1 !mb-0 text-sm"
            :value="manualInvitation.invitation_url"
          />
          <Button
            slate
            type="button"
            icon="i-lucide-copy"
            :label="$t('AGENT_MGMT.ADD.MANUAL_INVITATION.COPY')"
            @click.prevent="copyManualInvitation"
          />
        </div>
      </div>

      <div v-if="showSlaSchedule" class="flex flex-col w-full gap-1 py-2">
        <label class="flex items-center gap-2 text-sm text-n-slate-12">
          <input v-model="defineSchedule" type="checkbox" class="!m-0 w-fit" />
          {{ $t('CRM_SLA.AGENT.ADD_TOGGLE') }}
        </label>
        <p class="mb-1 text-xs text-n-slate-11">
          {{ $t('CRM_SLA.AGENT.SECTION_NOTE') }}
        </p>
      </div>

      <div class="flex flex-row justify-end w-full gap-2 px-0 py-2">
        <Button
          faded
          slate
          type="reset"
          :label="$t('AGENT_MGMT.ADD.CANCEL_BUTTON_TEXT')"
          @click.prevent="emit('close')"
        />
        <Button
          type="submit"
          :label="$t('AGENT_MGMT.ADD.FORM.SUBMIT')"
          :disabled="v$.$invalid || uiFlags.isCreating"
          :is-loading="uiFlags.isCreating"
        />
      </div>
    </form>

    <CrmScheduleEditor
      v-if="showScheduleEditor && createdAgent"
      owner-type="User"
      :owner-id="createdAgent.id"
      :owner-name="createdAgent.name"
      :schedule="null"
      @saved="finishAndClose"
      @close="finishAndClose"
    />
  </div>
</template>
