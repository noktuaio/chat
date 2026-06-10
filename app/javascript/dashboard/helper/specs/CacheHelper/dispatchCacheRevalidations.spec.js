import { dispatchCacheRevalidations } from '../../CacheHelper/dispatchCacheRevalidations';
import InboxesAPI from 'dashboard/api/inboxes';
import LabelsAPI from 'dashboard/api/labels';
import TeamsAPI from 'dashboard/api/teams';

vi.mock('dashboard/api/inboxes', () => ({
  default: {
    validateCacheKey: vi.fn(),
    refetchAndCommit: vi.fn(),
    extractDataFromResponse: vi.fn(),
  },
}));
vi.mock('dashboard/api/labels', () => ({
  default: {
    validateCacheKey: vi.fn(),
    refetchAndCommit: vi.fn(),
    extractDataFromResponse: vi.fn(),
  },
}));
vi.mock('dashboard/api/teams', () => ({
  default: {
    validateCacheKey: vi.fn(),
    refetchAndCommit: vi.fn(),
    extractDataFromResponse: vi.fn(),
  },
}));

describe('dispatchCacheRevalidations', () => {
  let store;

  beforeEach(() => {
    vi.clearAllMocks();
    store = { commit: vi.fn() };
  });

  it('refetches stale models and commits via their setMutation', async () => {
    InboxesAPI.validateCacheKey.mockResolvedValue(false);
    InboxesAPI.refetchAndCommit.mockResolvedValue({ data: { payload: [] } });
    InboxesAPI.extractDataFromResponse.mockReturnValue([{ id: 1 }]);
    LabelsAPI.validateCacheKey.mockResolvedValue(true);

    await dispatchCacheRevalidations(store, {
      inbox: 'inbox-key',
      label: 'label-key',
    });

    expect(InboxesAPI.refetchAndCommit).toHaveBeenCalledWith('inbox-key');
    expect(store.commit).toHaveBeenCalledWith('inboxes/SET_INBOXES', [
      { id: 1 },
    ]);
    expect(LabelsAPI.refetchAndCommit).not.toHaveBeenCalled();
    expect(store.commit).toHaveBeenCalledTimes(1);
  });

  it('skips models absent from the key payload', async () => {
    InboxesAPI.validateCacheKey.mockResolvedValue(true);

    await dispatchCacheRevalidations(store, { inbox: 'inbox-key' });

    expect(TeamsAPI.validateCacheKey).not.toHaveBeenCalled();
    expect(store.commit).not.toHaveBeenCalled();
  });

  it('treats missing keys as an empty payload', async () => {
    await dispatchCacheRevalidations(store);

    expect(InboxesAPI.validateCacheKey).not.toHaveBeenCalled();
    expect(store.commit).not.toHaveBeenCalled();
  });

  it('swallows per-model errors so one failure does not block the rest', async () => {
    InboxesAPI.validateCacheKey.mockResolvedValue(false);
    InboxesAPI.refetchAndCommit.mockRejectedValue(new Error('network down'));
    TeamsAPI.validateCacheKey.mockResolvedValue(false);
    TeamsAPI.refetchAndCommit.mockResolvedValue({ data: [] });
    TeamsAPI.extractDataFromResponse.mockReturnValue([{ id: 7 }]);

    await dispatchCacheRevalidations(store, {
      inbox: 'inbox-key',
      team: 'team-key',
    });

    expect(store.commit).toHaveBeenCalledWith('teams/SET_TEAMS', [{ id: 7 }]);
    expect(store.commit).toHaveBeenCalledTimes(1);
  });
});
