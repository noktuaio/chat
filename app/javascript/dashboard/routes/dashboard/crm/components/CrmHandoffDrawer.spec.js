import { mount, flushPromises } from '@vue/test-utils';
import { ref } from 'vue';
import CrmHandoffDrawer from './CrmHandoffDrawer.vue';

// Stub the surrounding harness (i18n, store, alerts, keyboard, API) so we can
// mount the drawer in isolation and assert the handoff payload round-trips the
// new pool + escalation_action fields correctly.
const getAiSettings = vi.fn();
const updateAiSettings = vi.fn(() =>
  Promise.resolve({ data: { payload: {} } })
);

vi.mock('dashboard/api/crmKanban', () => ({
  default: {
    getAiSettings: (...args) => getAiSettings(...args),
    updateAiSettings: (...args) => updateAiSettings(...args),
  },
}));
vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));
vi.mock('dashboard/composables', () => ({ useAlert: () => {} }));
vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch: vi.fn() }),
  useMapGetter: () => ref([{ id: 7, name: 'Maria' }]),
}));
vi.mock('dashboard/composables/useKeyboardEvents', () => ({
  useKeyboardEvents: () => {},
}));

const mountDrawer = (handoff = {}) => {
  getAiSettings.mockResolvedValue({
    data: { payload: { handoff, stages: [] } },
  });
  return mount(CrmHandoffDrawer, {
    props: { show: true, pipelineId: 1, stages: [] },
    global: { stubs: { Button: true, CrmHandoffFields: true } },
  });
};

describe('CrmHandoffDrawer new handoff fields', () => {
  beforeEach(() => {
    getAiSettings.mockReset();
    updateAiSettings.mockClear();
  });

  it('hydrates the pool + escalation_action fields from the loaded payload', async () => {
    const wrapper = mountDrawer({
      enabled: true,
      handoff_mode: 'r3_invite',
      pool_type: 'user',
      pool_id: 7,
      escalation_action: 'escalate',
      escalation_user_id: 7,
    });
    await flushPromises();

    expect(wrapper.vm.defaultHandoff.pool_type).toBe('user');
    expect(wrapper.vm.defaultHandoff.pool_id).toBe(7);
    expect(wrapper.vm.defaultHandoff.escalation_action).toBe('escalate');
  });

  it('sends the pool + escalation_action fields in the save payload', async () => {
    const wrapper = mountDrawer({
      enabled: true,
      handoff_mode: 'r3_invite',
      pool_type: 'user',
      pool_id: 7,
      escalation_action: 'escalate',
      escalation_user_id: 7,
    });
    await flushPromises();

    await wrapper.vm.saveSettings();

    expect(updateAiSettings).toHaveBeenCalledTimes(1);
    const [, body] = updateAiSettings.mock.calls[0];
    expect(body.ai_settings.handoff.pool_type).toBe('user');
    expect(body.ai_settings.handoff.pool_id).toBe(7);
    expect(body.ai_settings.handoff.escalation_action).toBe('escalate');
    expect(body.ai_settings.handoff.handoff_mode).toBe('r3_invite');
  });

  it('preserves a legacy escalate config on round-trip (no silent downgrade)', async () => {
    // Presenter resolves a legacy funnel (escalation_user_id set, no explicit
    // action) to escalation_action 'escalate'. Saving must send it back as
    // 'escalate', not default it to 'renotify'.
    const wrapper = mountDrawer({
      enabled: true,
      handoff_mode: 'r3_invite',
      pool_type: 'inbox',
      escalation_action: 'escalate',
      escalation_user_id: 7,
    });
    await flushPromises();

    await wrapper.vm.saveSettings();

    const [, body] = updateAiSettings.mock.calls[0];
    expect(body.ai_settings.handoff.escalation_action).toBe('escalate');
    expect(body.ai_settings.handoff.escalation_user_id).toBe(7);
  });
});
