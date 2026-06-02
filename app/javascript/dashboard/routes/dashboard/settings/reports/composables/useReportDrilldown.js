import { computed, ref } from 'vue';
import ReportsAPI from 'dashboard/api/reports';

export function useReportDrilldown() {
  const activeRequest = ref(null);
  const records = ref([]);
  const meta = ref({});
  const isFetching = ref(false);
  const isFetchingMore = ref(false);
  const hasError = ref(false);
  let requestToken = 0;

  const hasRecords = computed(() => records.value.length > 0);
  const hasMore = computed(() => {
    return records.value.length < (meta.value.total_count || 0);
  });

  const isCurrentRequest = token =>
    token === requestToken && !!activeRequest.value;

  const fetchPage = async (page, token = requestToken) => {
    if (!activeRequest.value) return;

    const request = activeRequest.value;
    const loadingState = page === 1 ? isFetching : isFetchingMore;
    loadingState.value = true;
    hasError.value = false;

    try {
      const response = await ReportsAPI.getDrilldown({
        ...request,
        page,
      });
      if (!isCurrentRequest(token)) return;

      meta.value = response.data.meta || {};
      records.value =
        page === 1
          ? response.data.payload || []
          : [...records.value, ...(response.data.payload || [])];
    } catch {
      if (!isCurrentRequest(token)) return;

      hasError.value = true;
    } finally {
      if (isCurrentRequest(token)) {
        loadingState.value = false;
      }
    }
  };

  const open = async request => {
    requestToken += 1;
    activeRequest.value = request;
    records.value = [];
    meta.value = {};
    hasError.value = false;
    isFetchingMore.value = false;
    await fetchPage(1, requestToken);
  };

  const close = () => {
    requestToken += 1;
    activeRequest.value = null;
    records.value = [];
    meta.value = {};
    hasError.value = false;
    isFetching.value = false;
    isFetchingMore.value = false;
  };

  const loadMore = () => {
    if (
      !activeRequest.value ||
      !hasMore.value ||
      isFetching.value ||
      isFetchingMore.value
    ) {
      return;
    }

    fetchPage((meta.value.current_page || 1) + 1, requestToken);
  };

  return {
    activeRequest,
    records,
    meta,
    isFetching,
    isFetchingMore,
    hasError,
    hasRecords,
    hasMore,
    open,
    close,
    loadMore,
  };
}
