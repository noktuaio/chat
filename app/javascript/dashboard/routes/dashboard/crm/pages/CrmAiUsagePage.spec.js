import { flushPromises, mount } from '@vue/test-utils';
import { BUS_EVENTS } from 'shared/constants/busEvents';
import CrmAiUsageAPI from 'dashboard/api/crmAiUsage';
import CrmAiUsagePage from './CrmAiUsagePage.vue';

const emitterHandlers = {};

vi.mock('dashboard/api/crmAiUsage', () => ({
  default: {
    get: vi.fn(),
    export: vi.fn(),
  },
}));

vi.mock('dashboard/composables/emitter', () => ({
  useEmitter: vi.fn((event, handler) => {
    emitterHandlers[event] = handler;
  }),
}));

vi.mock('shared/components/charts/BarChart.vue', () => ({
  default: {
    name: 'BarChart',
    props: {
      collection: {
        type: Object,
        default: () => ({}),
      },
    },
    template:
      '<div data-test-id="bar-chart">{{ collection.labels.join(",") }}</div>',
  },
}));

const makePayload = (overrides = {}) => ({
  account: { id: 85, name: 'Autonom.ia' },
  period: {
    since: '2026-06-21T12:00:00Z',
    until: '2026-06-28T12:00:00Z',
    group_by: 'day',
  },
  exchange_rate: {
    pair: 'USD-BRL',
    rate: 5.5,
    fetched_at: '2026-06-28T11:00:00Z',
    rate_unavailable: false,
  },
  totals: {
    usage_count: 2,
    period_spend: { cost_usd: 22.445455, cost_brl: 123.45 },
    average_cost: { cost_usd: 11.222727, cost_brl: 61.725 },
    cache_savings: { cost_usd: 1, cost_brl: 5.5 },
    cache_savings_pct: 4.27,
  },
  spend_by_resource: [
    {
      resource: 'Assistente de respostas',
      usage_count: 1,
      input_tokens: 100,
      cached_tokens: 20,
      output_tokens: 30,
      cost_usd: 10,
      cost_brl: 55,
    },
    {
      resource: 'Base de conhecimento',
      usage_count: 1,
      input_tokens: 50,
      cached_tokens: 5,
      output_tokens: 20,
      cost_usd: 2,
      cost_brl: 11,
    },
  ],
  time_series: [
    { timestamp: '2026-06-27T00:00:00Z', cost_usd: 10, cost_brl: 55 },
    { timestamp: '2026-06-28T00:00:00Z', cost_usd: 12.445455, cost_brl: 68.45 },
  ],
  history: {
    page: 1,
    per_page: 25,
    total_count: 2,
    rows: [
      {
        id: 2,
        created_at: '2026-06-28T11:00:00Z',
        resource: 'Assistente de respostas',
        account: { id: 85, name: 'Autonom.ia' },
        input_tokens: 100,
        cached_tokens: 20,
        output_tokens: 30,
        total_tokens: 130,
        cost_usd: 10,
        cost_brl: 55,
      },
    ],
  },
  ...overrides,
});

const mountPage = async (payload = makePayload()) => {
  CrmAiUsageAPI.get.mockResolvedValueOnce({ data: { payload } });
  const wrapper = mount(CrmAiUsagePage, {
    global: {
      stubs: {
        'fluent-icon': true,
      },
    },
  });
  await flushPromises();
  return wrapper;
};

describe('CrmAiUsagePage', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-06-28T12:00:00Z'));
    vi.clearAllMocks();
    Object.keys(emitterHandlers).forEach(key => {
      delete emitterHandlers[key];
    });
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('renders cards and spend by resource with humanized labels', async () => {
    const wrapper = await mountPage();

    expect(wrapper.text()).toContain('AI Management');
    expect(wrapper.text()).toContain('live');
    expect(wrapper.text()).toContain('Weekly spend');
    expect(wrapper.text()).toContain('AI uses');
    expect(wrapper.text()).toContain('Automatic savings');
    expect(wrapper.text()).toContain('Average cost per use');
    expect(wrapper.text()).toContain('Assistente de respostas');
    expect(wrapper.text()).toContain('Base de conhecimento');
    expect(wrapper.text()).not.toContain('agente_resposta');
  });

  it('formats cost_brl as decimal money without treating it as cents', async () => {
    const wrapper = await mountPage();

    expect(wrapper.text()).toContain('R$123.45');
    expect(wrapper.text()).not.toContain('R$1.23');
  });

  it('applies ActionCable delta to cards, chart data and history without refetching', async () => {
    const wrapper = await mountPage();

    emitterHandlers[BUS_EVENTS.CRM_AI_USAGE_CREATED]({
      id: 3,
      account_id: 85,
      resource: 'Criação de e-mail',
      created_at: '2026-06-28T12:01:00Z',
      input_tokens: 70,
      cached_tokens: 10,
      output_tokens: 20,
      total_tokens: 90,
      cost_usd: 1,
    });
    await wrapper.vm.$nextTick();

    expect(CrmAiUsageAPI.get).toHaveBeenCalledTimes(1);
    expect(wrapper.text()).toContain('Criação de e-mail');
    expect(wrapper.text()).toContain('R$128.95');
    expect(wrapper.text()).toContain('3');
    expect(wrapper.text()).toContain('90');
  });

  it('refetches on period change with the selected group_by', async () => {
    const wrapper = await mountPage();
    CrmAiUsageAPI.get.mockResolvedValueOnce({
      data: { payload: makePayload({ time_series: [] }) },
    });

    await wrapper
      .findAll('button')
      .find(button => button.text() === 'Month')
      .trigger('click');
    await flushPromises();

    expect(CrmAiUsageAPI.get).toHaveBeenCalledTimes(2);
    expect(CrmAiUsageAPI.get).toHaveBeenLastCalledWith(
      expect.objectContaining({ group_by: 'day' })
    );
    expect(wrapper.text()).toContain('Monthly spend');
    expect(wrapper.text()).toContain('Monthly spend (by day)');
  });
});
