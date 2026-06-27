import { mount } from '@vue/test-utils';
import CrmCardDrawer from './CrmCardDrawer.vue';

// Stub the store/router/composables/APIs the drawer reaches for, so we can mount
// it in isolation and assert the form-reset reactivity that the realtime-churn
// fix changed (props.stages dropped from the reset watcher, props.card kept).
vi.mock('vuex', () => ({
  useStore: () => ({ getters: {}, dispatch: vi.fn() }),
}));
vi.mock('vue-router', () => ({
  useRoute: () => ({ params: {} }),
  useRouter: () => ({ push: vi.fn() }),
}));
vi.mock('dashboard/composables', () => ({
  useAlert: () => () => {},
}));
vi.mock('dashboard/composables/useKeyboardEvents', () => ({
  useKeyboardEvents: () => {},
}));
vi.mock('dashboard/api/contacts', () => ({
  default: { search: vi.fn().mockResolvedValue({ data: { payload: [] } }) },
}));
vi.mock('dashboard/api/crmKanban', () => ({
  default: {
    getFollowUpMessagingWindow: vi.fn().mockResolvedValue({ data: {} }),
  },
}));
vi.mock('dashboard/api/whatsappApiMessageTemplates', () => ({
  default: { get: vi.fn().mockResolvedValue({ data: [] }) },
}));

const makeStages = () => [
  { id: 10, name: 'Novo', color: '#2563eb' },
  { id: 11, name: 'Em atendimento', color: '#0891b2' },
];

const mountDrawer = (props = {}) =>
  mount(CrmCardDrawer, {
    props: {
      show: true,
      mode: 'edit',
      card: { id: 5, title: 'Card A', stage_id: 10 },
      stages: makeStages(),
      pipelineId: 1,
      ...props,
    },
    global: {
      stubs: {
        CrmCardAiPanel: true,
        CrmCardSummaryPanel: true,
        CrmCardAutoFollowupStatus: true,
        PhoneNumberInput: true,
      },
    },
  });

describe('CrmCardDrawer form reset vs realtime churn', () => {
  it('keeps in-progress card edits when props.stages churns (realtime/poll)', async () => {
    const wrapper = mountDrawer();
    wrapper.vm.form.title = 'Card A editado';
    await wrapper.vm.$nextTick();

    // Realtime event rebuilds board.stages into a new array; the selected card
    // is NOT rebound, so editing must survive.
    await wrapper.setProps({ stages: makeStages() });

    expect(wrapper.vm.form.title).toBe('Card A editado');
  });

  it('resets the form when a different card is opened', async () => {
    const wrapper = mountDrawer();
    wrapper.vm.form.title = 'dirty';

    await wrapper.setProps({ card: { id: 6, title: 'Card B', stage_id: 11 } });

    expect(wrapper.vm.form.title).toBe('Card B');
  });

  it('re-hydrates when the shallow card is replaced by its detailed payload (same id)', async () => {
    const wrapper = mountDrawer();
    expect(wrapper.vm.form.description).toBe('');

    // Parent opens with a shallow card, then swaps in the detailed object
    // (same id, fuller data). The reset watcher must pick this up.
    await wrapper.setProps({
      card: { id: 5, title: 'Card A', stage_id: 10, description: 'detalhe' },
    });

    expect(wrapper.vm.form.description).toBe('detalhe');
  });
});
