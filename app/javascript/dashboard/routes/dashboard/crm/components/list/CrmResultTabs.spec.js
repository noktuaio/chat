import { mount } from '@vue/test-utils';
import { useI18n } from 'vue-i18n';
import CrmResultTabs from './CrmResultTabs.vue';

vi.mock('vue-i18n');

describe('CrmResultTabs', () => {
  beforeEach(() => {
    useI18n.mockReturnValue({ t: key => key });
  });

  const activeButton = wrapper =>
    wrapper
      .findAll('button')
      .find(btn => btn.attributes('aria-pressed') === 'true');

  it('renders the three everyday outcome tabs', () => {
    const wrapper = mount(CrmResultTabs, { props: { modelValue: 'open' } });
    expect(wrapper.findAll('button')).toHaveLength(3);
  });

  it('marks the matching tab as active', () => {
    const wrapper = mount(CrmResultTabs, { props: { modelValue: 'won' } });
    expect(activeButton(wrapper).text()).toBe('CRM_KANBAN.RESULT_FILTER.WON');
  });

  it('marks no tab active when result is empty ("Todos")', () => {
    const wrapper = mount(CrmResultTabs, { props: { modelValue: '' } });
    expect(activeButton(wrapper)).toBeUndefined();
  });

  it('emits update:modelValue with the clicked tab value', async () => {
    const wrapper = mount(CrmResultTabs, { props: { modelValue: 'open' } });
    await wrapper.get('button[data-value="lost"]').trigger('click');
    expect(wrapper.emitted('update:modelValue')[0]).toEqual(['lost']);
  });
});
