import { mount } from '@vue/test-utils';
import { ref } from 'vue';
import CrmPipelineDrawer from './CrmPipelineDrawer.vue';

// The drawer pulls global config + permissions; stub them so we can mount it in
// isolation and focus on the form-reset reactivity that the realtime-churn fix
// changed.
vi.mock('vuex', () => ({
  useStore: () => ({ getters: {} }),
}));
vi.mock('../composables/useCrmPermissions', () => ({
  useCrmPermissions: () => ({ canManageAi: ref(false) }),
}));
vi.mock('dashboard/composables/useKeyboardEvents', () => ({
  useKeyboardEvents: () => {},
}));

// Fresh array + fresh objects every call: this is exactly what the Vuex board
// getter returns on each realtime card event / poll (board.stages is rebuilt).
const makeStages = () => [
  {
    id: 10,
    name: 'Novo',
    color: '#2563eb',
    win_probability: 10,
    wip_limit: '',
  },
  {
    id: 11,
    name: 'Em atendimento',
    color: '#0891b2',
    win_probability: 35,
    wip_limit: '',
  },
];

const mountDrawer = (props = {}) =>
  mount(CrmPipelineDrawer, {
    props: {
      show: true,
      mode: 'edit',
      pipeline: { id: 1, name: 'Funil' },
      stages: makeStages(),
      ...props,
    },
    global: {
      stubs: { CrmStageAutomationsPanel: true, CrmAiSettingsPanel: true },
    },
  });

describe('CrmPipelineDrawer form reset vs realtime churn', () => {
  it('keeps in-progress stage edits when props.stages churns with the same ids', async () => {
    const wrapper = mountDrawer();
    wrapper.vm.form.stages[0].name = 'Novo Editado';
    await wrapper.vm.$nextTick();

    // Realtime event: same stages, brand-new array/object references.
    await wrapper.setProps({ stages: makeStages() });

    expect(wrapper.vm.form.stages[0].name).toBe('Novo Editado');
  });

  it('resets the form when the drawer opens', async () => {
    const wrapper = mountDrawer({ show: false });
    wrapper.vm.form.name = 'dirty';

    await wrapper.setProps({ show: true });

    expect(wrapper.vm.form.name).toBe('Funil');
  });

  it('resets the form when the target pipeline identity changes', async () => {
    const wrapper = mountDrawer();
    wrapper.vm.form.name = 'dirty';

    await wrapper.setProps({ pipeline: { id: 2, name: 'Outro Funil' } });

    expect(wrapper.vm.form.name).toBe('Outro Funil');
  });

  it('drops a server-deleted stage while preserving edits to the survivors', async () => {
    const wrapper = mountDrawer();
    wrapper.vm.form.stages[0].name = 'Novo Editado';
    await wrapper.vm.$nextTick();

    // Stage id 11 deleted server-side; the board refetch drops it from props.
    await wrapper.setProps({ stages: [makeStages()[0]] });

    expect(wrapper.vm.form.stages).toHaveLength(1);
    expect(wrapper.vm.form.stages[0].id).toBe(10);
    expect(wrapper.vm.form.stages[0].name).toBe('Novo Editado');
  });
});
