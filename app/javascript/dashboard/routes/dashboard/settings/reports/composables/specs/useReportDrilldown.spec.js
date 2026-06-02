import { flushPromises, mount } from '@vue/test-utils';
import ReportsAPI from 'dashboard/api/reports';
import { useReportDrilldown } from '../useReportDrilldown';

vi.mock('dashboard/api/reports', () => ({
  default: {
    getDrilldown: vi.fn(),
  },
}));

const deferredPromise = () => {
  let resolve;
  let reject;
  const promise = new Promise((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });

  return { promise, resolve, reject };
};

describe('useReportDrilldown', () => {
  const mountComposable = () =>
    mount({
      setup() {
        return useReportDrilldown();
      },
      template: '<div />',
    });

  afterEach(() => {
    vi.clearAllMocks();
  });

  it('ignores stale responses when a newer request is opened first', async () => {
    const firstRequest = deferredPromise();
    const secondRequest = deferredPromise();
    ReportsAPI.getDrilldown
      .mockReturnValueOnce(firstRequest.promise)
      .mockReturnValueOnce(secondRequest.promise);

    const wrapper = mountComposable();
    wrapper.vm.open({ metric: 'conversations_count', bucketTimestamp: 1 });
    wrapper.vm.open({ metric: 'conversations_count', bucketTimestamp: 2 });

    secondRequest.resolve({
      data: {
        meta: { current_page: 1, total_count: 1 },
        payload: [{ id: 'second' }],
      },
    });
    await flushPromises();

    expect(wrapper.vm.records).toEqual([{ id: 'second' }]);
    expect(wrapper.vm.meta).toEqual({ current_page: 1, total_count: 1 });

    firstRequest.resolve({
      data: {
        meta: { current_page: 1, total_count: 1 },
        payload: [{ id: 'first' }],
      },
    });
    await flushPromises();

    expect(wrapper.vm.records).toEqual([{ id: 'second' }]);
    expect(wrapper.vm.meta).toEqual({ current_page: 1, total_count: 1 });
  });
});
